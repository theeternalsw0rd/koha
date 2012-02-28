package C4::Auth_with_f1;

# Copyright 2000-2002 Katipo Communications
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
#use warnings; FIXME - Bug 2505
use Digest::MD5 qw(md5_base64);

use C4::Debug;
use C4::Context;
use C4::Members qw(AddMember changepassword);
use C4::Members::Attributes;
use C4::Members::AttributeTypes;
use C4::Utils qw( :all );
use List::MoreUtils qw( any );
use Data::Dumper;
use Net::OAuth;
use HTTP::Request::Common;
use MIME::Base64;
use LWP::UserAgent;
use URI::Escape;
use JSON;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $debug);

BEGIN {
	require Exporter;
	$VERSION = 3.10;	# set the version for version checking
	@ISA    = qw(Exporter);
	@EXPORT = qw( checkpw_f1 );
}

# Redefine checkpw_f1:
# connect to f1
# ~ then gets the f1 entry
# ~ and calls the memberadd if necessary

use vars qw($prefhost $client_key $client_secret);
my $context = C4::Context->new() 	or die 'C4::Context->new failed';
my $church_code = C4::Context->preference('f1ChurchCode');
my $staging = C4::Context->preference('f1Staging');
my $prefhost = undef;
if($staging) {
	$prefhost  = "https://" . $church_code . ".staging.fellowshiponeapi.com";
}
else {
	$prefhost  = "https://" . $church_code . ".fellowshiponeapi.com";
}
my $client_key = C4::Context->preference('f1ClientKey');
my $client_secret = C4::Context->preference('f1ClientSecret');
my $useragent = LWP::UserAgent->new;
my $logindata = {
	consumer_key => $client_key,
	consumer_secret => $client_secret,
	signature_method => 'HMAC-SHA1',
	nonce => undef,
	request_url => $prefhost.'/v1/WeblinkUser/AccessToken',
	request_method => 'POST',
	timestamp => undef,
	token => undef,
	token_secret => undef,
	callback => undef,
	extra_params => {
	}
};
# thanks to Cameron King for donating oauth_request and oauth_login
# from his Ecc12-FellowshipOne-API-OAuth library
sub oauth_request {
	my $name = shift or return;;
	my $content = shift or undef;

	$logindata->{'nonce'} = int(rand(2 ** 32));
	$logindata->{'timestamp'} = time();

 	my $request = Net::OAuth->request($name)->new(%{$logindata});
 	$request->sign();

 	my $getpost = undef;
 	my $response = undef;

	if($logindata->{'request_method'} eq 'POST') {
		$getpost = POST $logindata->{'request_url'},
			'Authorization' => $request->to_authorization_header(),
			'Content_Type' => 'application/json',
 			'Accept' => 'application/json',
			'Content' => $content;
	} elsif($logindata->{'request_method'} eq 'GET') {
		$getpost = GET $logindata->{'request_url'},
			'Authorization' => $request->to_authorization_header(),
			'Content_Type' => 'application/json',
			'Accept' => 'application/json';
	}
 	$response = $useragent->request($getpost);
	return $response;
}

sub oauth_login {
	my $userid = shift or return;
	my $userpass = shift or return;
	my $unencodedlogin = $userid.' '.$userpass;
	my $loginstring = encode_base64($unencodedlogin);
	my $f1_id = undef;
	$loginstring =~ s/\s//g;

	my $response = oauth_request("RequestToken", uri_escape("$loginstring"));

	if ($response->{'_rc'} ne '200') {
		return undef;
	}

	# save access token
	if ($response->is_success) {	
		my $response = Net::OAuth->response('RequestToken')->from_post_body($response->content);
		$logindata->{'token'} = $response->token;
		$logindata->{'token_secret'} = $response->token_secret;
	} else {
		return undef;
	}
	$f1_id = $response->{'_headers'}->header('content-location');
	$f1_id =~ s/.*\///g;
	return $f1_id;
}

sub get_hash_from_f1 {
	my $externalid = shift or return;
	my $userid = shift or return;
	my $password = md5_base64(shift) or return;
	my $response = undef;
	my $dateofbirth = undef;
	my $dateenrolled = undef;
	my @date = ();
	my $year = undef;
	my $privilege = undef;
	my %data = (
		externalid => $externalid,
		firstname => undef,
		surname => undef,
		userid => $userid,
		password => $password,
		categorycode => undef, # koha privilege
		address => undef,
		address2 => '',
		city => undef,
		state => '',
		zipcode => undef,
		phone => '',
		mobile => '',
		phonepro => '',
		email => '',
		emailpro => '',
		cardnumber => undef,
		dateofbirth => undef,
		dateenrolled => undef,
		dateexpiry => undef,
		branchcode => undef,
		flags => ''
	);
	$logindata->{'request_method'} = 'GET';
	$logindata->{'request_url'} = $prefhost . '/v1/People/Search.json?id=' . $externalid . '&include=addresses,communications,attributes';
	$response = decode_json(oauth_request("ProtectedResource")->{'_content'});
	for my $people(@{$response->{'results'}->{'person'}}) {
		$data{'firstname'} = $people->{'firstName'};
		$data{'surname'} = $people->{'lastName'};
		$data{'cardnumber'} = $people->{'barCode'};
		$dateofbirth = $people->{'dateOfBirth'};
		$dateofbirth =~ s/T.*//g;
		$data{'dateofbirth'} = $dateofbirth;
		$dateenrolled = $people->{'createdDate'};
		$dateenrolled =~ s/T.*//g;
		$data{'dateenrolled'} = $dateenrolled;
		@date = split(/-/, $dateofbirth);
		$year = int($date[0]);
		$year += 200;
		$data{'dateexpiry'} = "$year-" . $date[1] . "-" . $date[2];
		for my $addresses(@{$people->{'addresses'}->{'address'}}) {
			if ($addresses->{'addressType'}->{'name'} eq 'Primary') {
				$data{'address'} = $addresses->{'address1'};
				if ($addresses->{'address2'} ne undef) {
					$data{'address2'} = $addresses->{'address2'};
				}
				$data{'city'} = $addresses->{'city'};
				if ($addresses->{'stProvince'} ne undef) {
					$data{'state'} = $addresses->{'stProvince'};
				}
				$data{'zipcode'} = $addresses->{'postalCode'};
			}
		}
		for my $attributes(@{$people->{'attributes'}->{'attribute'}}) {
			if($attributes->{'attributeGroup'}->{'name'} eq C4::Context->preference('f1PatronTypeAttribute')) {
				$data{'categorycode'} = $attributes->{'attributeGroup'}->{'attribute'}->{'name'};
=begin comment
				if($data{'categorycode'} eq 'LS') {
					$data{'flags'} = '1670'; #permission flags
				}
=end comment
=cut
			}
			if($attributes->{'attributeGroup'}->{'name'} eq C4::Context->preference('f1FlagsAttribute')) {
				$data{'flags'} = $attributes->{'attributeGroup'}->{'attribute'}->{'name'};
			}
			if($attributes->{'attributeGroup'}->{'name'} eq C4::Context->preference('f1DefaultBranchAttribute')) {
				$data{'branchcode'} = $attributes->{'attributeGroup'}->{'attribute'}->{'name'};
			}
		}
		for my $communications(@{$people->{'communications'}->{'communication'}}) {
			if ($communications->{'communicationGeneralType'} eq 'Telephone') {
				if ($communications->{'communicationType'}->{'name'} eq 'Home Phone') {
					$data{'phone'} = $communications->{'communicationValue'};
				}
				if ($communications->{'communicationType'}->{'name'} eq 'Work Phone') {
					$data{'phonepro'} = $communications->{'communicationValue'};
				}
				if ($communications->{'communicationType'}->{'name'} eq 'Mobile') {
					$data{'mobile'} = $communications->{'communicationValue'};
				}
			}
			if ($communications->{'communicationType'}->{'name'} eq 'Email') {
				$data{'email'} = $communications->{'communicationValue'};
			}
			if ($communications->{'communicationType'}->{'name'} eq 'Work Email') {
				$data{'emailpro'} = $communications->{'communicationValue'};
			}
		}
	}
	return %data;
}

sub checkpw_f1 {
    my ($userid, $password) = @_;
	
	my $externalid = oauth_login($userid, $password);
	
	if($externalid eq undef) {
		warn "Fellowship One authentication failed";
		return 0;
	}

	# authentication has worked, but more stuff to do.
    my (%borrower);
	my ($borrowernumber,$cardnumber) = exists_local($externalid);
	%borrower = get_hash_from_f1($externalid, $userid, $password);

	if ($borrowernumber) {
		my $c2 = &update_local($userid,$password,$borrowernumber,\%borrower) || '';
		($cardnumber eq $c2) or warn "update_local returned cardnumber '$c2' instead of '$cardnumber'";
	} elsif (!$borrowernumber) {
		$borrowernumber = AddMember(%borrower) or die "AddMember failed";
	}
	if (C4::Context->preference('ExtendedPatronAttributes') && $borrowernumber) {
   		my @types = C4::Members::AttributeTypes::GetAttributeTypes();
		my @attributes = grep{my $key=$_; any{$_ eq $key}@types;} keys %borrower;
        my $extended_patron_attributes;
        @{$extended_patron_attributes} =
          map { { code => $_, value => $borrower{$_} } } @attributes;
		my @errors;
		#Check before add
		for (my $i; $i< scalar(@$extended_patron_attributes)-1;$i++) {
			my $attr=$extended_patron_attributes->[$i];
			unless (C4::Members::Attributes::CheckUniqueness($attr->{code}, $attr->{value}, $borrowernumber)) {
				unshift @errors, $i;
				warn "ERROR_extended_unique_id_failed $attr->{code} $attr->{value}";
			}
		}
		#Removing erroneous attributes
		foreach my $index (@errors){
			@$extended_patron_attributes=splice(@$extended_patron_attributes,$index,1);
		}
           C4::Members::Attributes::SetBorrowerAttributes($borrowernumber, $extended_patron_attributes);
  	}
return(1, $cardnumber, $userid);
}

sub exists_local($) {
	my $arg = shift;
	my $dbh = C4::Context->dbh;
	my $select = "SELECT borrowernumber,cardnumber FROM borrowers ";

	my $sth = $dbh->prepare("$select WHERE externalid=?");	# was cardnumber=?
	$sth->execute($arg);
	$debug and printf STDERR "Userid '$arg' exists_local? %s\n", $sth->rows;
	($sth->rows == 1) and return $sth->fetchrow;

	$sth = $dbh->prepare("$select WHERE cardnumber=?");
	$sth->execute($arg);
	$debug and printf STDERR "Cardnumber '$arg' exists_local? %s\n", $sth->rows;
	($sth->rows == 1) and return $sth->fetchrow;
	return 0;
}

sub _do_changepassword {
    my ($userid, $borrowerid, $digest) = @_;
    $debug and print STDERR "changing local password for borrowernumber=$borrowerid to '$digest'\n";
    changepassword($userid, $borrowerid, $digest);

	# Confirm changes
	my $sth = C4::Context->dbh->prepare("SELECT password,cardnumber FROM borrowers WHERE borrowernumber=? ");
	$sth->execute($borrowerid);
	if ($sth->rows) {
		my ($md5password, $cardnum) = $sth->fetchrow;
        ($digest eq $md5password) and return $cardnum;
		warn "Password mismatch after update to cardnumber=$cardnum (borrowernumber=$borrowerid)";
		return undef;
	}
	die "Unexpected error after password update to userid/borrowernumber: $userid / $borrowerid.";
}

sub update_local($$$$) {
	my   $userid   = shift             or return undef;
	my   $digest   = md5_base64(shift) or return undef;
	my $borrowerid = shift             or return undef;
	my $borrower   = shift             or return undef;
	my @keys = keys %$borrower;
	my $dbh = C4::Context->dbh;
	my $query = "UPDATE  borrowers\nSET     " . 
		join(',', map {"$_=?"} @keys) .
		"\nWHERE   borrowernumber=? "; 
	my $sth = $dbh->prepare($query);
	if ($debug) {
		print STDERR $query, "\n",
			join "\n", map {"$_ = '" . $borrower->{$_} . "'"} @keys;
		print STDERR "\nuserid = $userid\n";
	}
	$sth->execute(
		((map {$borrower->{$_}} @keys), $borrowerid)
	);

	# MODIFY PASSWORD/LOGIN
	_do_changepassword($userid, $borrowerid, $digest);
}

1;
__END__

=head1 NAME

C4::Auth - Authenticates Koha users

=head1 SYNOPSIS

  use C4::Auth_with_f1;

=head1 Fellowship One Configuration

    This module is specific to Fellowship One authentification. It requires Data::Dumper, Net::OAuth, 
    HTTP::Request, MIME::Base64 LWP::UserAgent, URI::Escape, JSON packages, a Fellowship
    One account and a 2nd Party API key from Fellowship One.

	To use it, you need configure f1Authentication in the Administration area of Global System Preferences.
    
    On Fellowship One, you will need to create the following Attribute Groups: 'Koha Patron Type', 'Koha Default Branch',
    and 'Koha Flags' (or name them yourself and change the defaults in the Global System Preferences). You will put the categorycode
    values from the categories table from the database as the Individual Attributes for the 'Koha Patron Type' group.  Likewise the
    branchcode values from the branches table will be used in the 'Koha Default Branch' group. For the 'Koha Flags' will contain the
    permissions flags that you want to be able to use.  To find out these flags, you will need to apply the permissions to a local
    user first and look up the flags field for that user in the borrowers table.
    
    You can also do the 'Koha Flags' by applying some logic when looking up the patron type (this requires each permission level to have
    a matching patron type).  Some example code for doing this is provided in the comment beginning on line 205 of this file.  If going
    this route, remove the 'Koha Flags' if block for a marginal improvement (it will still work if you don't do this).
