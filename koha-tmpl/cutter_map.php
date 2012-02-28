<?php
function string_to_ascii($string)
{
    $ascii = 0;
    $uppercase = strtoupper($string);
    for($i=0;$i<strlen($string);$i++)
    {
    	$ascii *= 100;
   	    $ascii += ord($uppercase[$i]);
    }
    while($ascii < 100000000000000000)
    {
        $ascii *= 100;
    }
    return($ascii);
}
include("db.php");
/* db.php sets $user, $password, $host, and $database */
mysql_connect($host, $user, $password);
@mysql_select_db($database) or die( "Unable to select database");
$biblionumber = mysql_real_escape_string($_GET['biblionumber']);
$query = "SELECT * FROM biblio WHERE biblionumber=$biblionumber";
$result = mysql_query($query) or die(mysql_error());
$record = mysql_fetch_assoc($result);
mysql_close();
$author = preg_replace("/(\\.|'|\")/", '', $record['author']);
$author_last = preg_replace('/, .*/', '', $author);
$author_first = preg_replace('/.*, /', '', $author);
$title = preg_replace('/^[^A-Z]*/', '', strtoupper($record['title']));
$author_last_init = $author_last[0];
$author_short = preg_replace('/(Sc.|S.|A.|E.|I.|O.|U.|[BCDFGHJKLMNPQRTVWXYZ]).*/', '\\1', $author_last);
$title_first = substr(preg_replace('/(THE |A |AN )/', '', $title), 0, 1);
$cutter_number = 0;
if($author_last == "Jones")
{
	$cutter_number = 72;
    if(ord($author_first) < ord("L"))
    {
        $cutter_number = 71;
    }
    if(ord($author_first) >= ord("Z"))
    {
        $cutter_number = 73;
    }
}
elseif ($author_last == "Smith")
{
    if(ord($author_first) < ord("J"))
    {
        $cutter_number = 5;
    }
    else
    {
        $cutter_number = 6;
    }
}
else
{
    $author_ascii = string_to_ascii($author_last);
    $query = "SELECT * FROM cutter_map WHERE hash LIKE '".$author_last_init."%' ORDER BY id ASC";
    mysql_connect($host, $user, $password);
    @mysql_select_db($database) or die( "Unable to select database");
    $result = mysql_query($query) or die(mysql_error());
    $j = 0;
    while($record = mysql_fetch_assoc($result)) 
    {
        $arr[$j]['ascii'] = string_to_ascii($record['hash']);
        $arr[$j]['id'] = $record['id'];
        $arr[$j]['value'] = $record['value'];
        $j++;
    }
    mysql_close();
    for($k=0;$k<$j;$k++)
    {
        if($arr[$k]['ascii'] == $author_ascii)
        {
            $cutter_number = $arr[$k]['value'];
            break;
        }
        if($arr[$k]['ascii'] > $author_ascii)
        {
            $key = $k - 1;
            $cutter_number = $arr[$key]['value'];
            break;
        }
    }
    if($cutter_number == 0)
    {
        $key = $k - 1;
        $cutter_number = $arr[$key]['value'];
    }
}
echo $author_short.$cutter_number.$title_first;
?>
