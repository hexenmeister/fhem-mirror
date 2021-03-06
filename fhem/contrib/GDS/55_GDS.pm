# $Id$

# copyright and license informations
=pod
###################################################################################################
#
#	55_GDS.pm
#
#	An FHEM Perl module to retrieve data from "Deutscher Wetterdienst"
#
#	Copyright: betateilchen ®
#
#   includes:  some patches provided by jensb
#              forecasts    provided by jensb
#
#	This file is part of fhem.
#
#	Fhem is free software: you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation, either version 2 of the License, or
#	(at your option) any later version.
#
#	Fhem is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
###################################################################################################
=cut

package main;

use strict;
use warnings;
use feature qw/say switch/;

use Blocking;
use Net::FTP;
use XML::Simple;
use Data::Dumper;

eval { use GDSweblink; };

no if $] >= 5.017011, warnings => 'experimental';

my ($bulaList, $cmapList, %rmapList, $fmapList, %bula2bulaShort, %bulaShort2dwd, %dwd2Dir, %dwd2Name,
	$alertsXml, %capCityHash, %capCellHash, $sList, $aList, $fList, $fcmapList, $tempDir, @weekdays);

###################################################################################################
#
#  Main routines
#
###################################################################################################

sub GDS_Initialize($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};

	return "This module must not be used on microso... platforms!" if($^O =~ m/Win/);

	$hash->{DefFn}		=	"GDS_Define";
	$hash->{UndefFn}	=	"GDS_Undef";
	$hash->{GetFn}		=	"GDS_Get";
	$hash->{SetFn}		=	"GDS_Set";
	$hash->{ShutdownFn}	=	"GDS_Shutdown";
	$hash->{NotifyFn}   =   "GDS_Notify";
	$hash->{NOTIFYDEV}  =   "global";
	$hash->{AttrFn}		=	"GDS_Attr";
	$hash->{AttrList}	=	"disable:0,1 ".
							"gdsFwName gdsFwType:0,1,2,3,4,5,6,7 gdsAll:0,1 ".
							"gdsDebug:0,1 gdsLong:0,1 gdsPolygon:0,1 ".
							"gdsSetCond gdsSetForecast gdsPassiveFtp:0,1 ".
							"gdsHideFiles:0,1 ".
							$readingFnAttributes;

    $tempDir  = "/tmp/";
    $aList    = "please_use_rereadcfg_first";
	$sList    = $aList;
 	$fList    = $aList;

}

sub GDS_Define($$$) {
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my ($found, $dummy);

	return "syntax: define <name> GDS <username> <password> [<host>]" if(int(@a) != 4 ); 
	my $name = $hash->{NAME};

	$hash->{helper}{USER}		= $a[2];
	$hash->{helper}{PASS}		= $a[3];
	$hash->{helper}{URL}		= defined($a[4]) ? $a[4] : "ftp-outgoing2.dwd.de";
	$hash->{helper}{INTERVAL}   = 1200;

	Log3($name, 4, "GDS $name: created");
	Log3($name, 4, "GDS $name: tempDir=".$tempDir);

    GDS_addExtension("GDS_CGI","gds","GDS Files");

	fillMappingTables($hash);
	initDropdownLists($hash);

	readingsSingleUpdate($hash, '_tzOffset', _calctz(time,localtime(time))*3600, 0);
	readingsSingleUpdate($hash, 'state', 'active',1);

	return undef;
}

sub GDS_Undef($$) {
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash);
    my $url = '/gds';
    delete $data{FWEXT}{$url} if int(devspec2array('TYPE=GDS')) == 1;
	return undef;
}

sub GDS_Shutdown($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	Log3 ($name,4,"GDS $name: shutdown requested");
	return undef;
}

sub GDS_Notify ($$) {
  my ($hash,$dev) = @_;
  my $name = $hash->{NAME};
  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED/, @{$dev->{CHANGED}}));

  my $d;
  
  GDS_Get($hash,undef,'rereadcfg');

  $d = AttrVal($name,'gdsSetCond',undef);
  GDS_Set($hash,undef,'conditions',$d) if(defined($d));

  $d = AttrVal($name,'gdsSetForecast',undef);
  GDS_Set($hash,undef,'forecasts',$d) if(defined($d));

  return undef;
}

sub GDS_Set($@) {
	my ($hash, @a) = @_;
	my $name = $hash->{NAME};
	my $usage =	"Unknown argument, choose one of ".
	            "clear:alerts,conditions,forecasts,all ".
				"conditions:$sList ".
				"forecasts:$fList ".
	            "help:noArg ".
	            "update:noArg ";				;

	readingsSingleUpdate($hash, '_tzOffset', _calctz(time,localtime(time))*3600, 0);

	my $command		= lc($a[1]);
	my $parameter	= $a[2] if(defined($a[2]));

	my ($result, $next);

	$hash->{LOCAL} = 1;

	return $usage if $command eq '?';

	if(IsDisabled($name)) {
		readingsSingleUpdate($hash, 'state', 'disabled', 0);
		return "GDS $name is disabled. Aborting..." if IsDisabled($name);
	}

	readingsSingleUpdate($hash, 'state', 'active', 0);

	given($command) {
		when("clear"){
			CommandDeleteReading(undef, "$name a_.*")
			       if(defined($parameter) && ($parameter eq "all" || $parameter eq "alerts"));
			CommandDeleteReading(undef, "$name c_.*")    
			       if(defined($parameter) && ($parameter eq "all" || $parameter eq "conditions"));
			CommandDeleteReading(undef, "$name g_.*")
			       if(defined($parameter) && ($parameter eq "all" || $parameter eq "conditions"));
			CommandDeleteReading(undef, "$name fc.?_.*") 
			       if(defined($parameter) && ($parameter eq "all" || $parameter eq "forecasts"));
			}

		when("help"){
			$result = setHelp();
			break;
			}

		when("update"){
			RemoveInternalTimer($hash);
			GDS_GetUpdate($hash);
			break;
			}

		when("conditions"){
			retrieveConditions($hash, "c", @a);
            $attr{$name}{gdsSetCond} = ReadingsVal($name,'c_stationName',undef);
			$next = gettimeofday()+$hash->{helper}{INTERVAL};
			readingsSingleUpdate($hash, "_nextUpdate", localtime($next), 1);
			RemoveInternalTimer($hash);
			InternalTimer($next, "GDS_GetUpdate", $hash, 1);
			break;
			}

		when("forecasts"){
			CommandDeleteReading(undef, "$name fc.?_.*") if($parameter ne AttrVal($name,'gdsSetForecast',''));
			retrieveForecasts($hash, "fc", @a);
			my $station = ReadingsVal($name, 'fc_stationName', undef);
			if (defined($station)) {
				$attr{$name}{gdsSetForecast} = $station;
			}
			break;
			}

		default { return $usage; };
	}
	return $result;
}

sub GDS_Get($@) {
	my ($hash, @a) = @_;
	my $command		= lc($a[1]);
	my $parameter	= $a[2] if(defined($a[2]));
	my $name = $hash->{NAME};

	$hash->{LOCAL} = 1;

	my $usage = "Unknown argument $command, choose one of help:noArg rereadcfg:noArg ".
				"list:stations,capstations,data ".
				"alerts:".$aList." ".
				"conditions:".$sList." ".
				"conditionsmap:".$cmapList." ".
				"forecasts:".$fcmapList." ".
				"forecastsmap:".$fmapList." ".
				"radarmap:".$cmapList." ".
				"warningsmap:"."Deutschland,Bodensee,".$bulaList." ".
				"warnings:".$bulaList;

	return $usage if $command eq '?';

	if(IsDisabled($name)) {
		readingsSingleUpdate($hash, 'state', 'disabled', 0);
		return "GDS $name is disabled. Aborting..." if IsDisabled($name);
	}

	readingsSingleUpdate($hash, 'state', 'active', 0);
	readingsSingleUpdate($hash, '_tzOffset', _calctz(time,localtime(time))*3600, 0);

	my ($result, @datensatz, $found);

	given($command) {

		when("conditionsmap"){
			# retrieve map: current conditions
			retrieveFile($hash,$command,$parameter,undef);
			break;
		}

		when("forecastsmap"){
			# retrieve map: forecasts
			retrieveFile($hash,$command,$parameter,undef);
			break;
		}

		when("warningsmap"){
			# retrieve map: warnings
			retrieveFile($hash,$command,$parameter,undef);
			break;
		}

		when("radarmap"){
			# retrieve map: radar
			$parameter = ucfirst($parameter);
			retrieveFile($hash,$command,$parameter,$rmapList{$parameter});
			break;
			}

		when("help"){
			$result = getHelp();
			break;
			}

		when("list"){
			given($parameter){
				when("capstations")	{ $result = getListCapStations($hash,$parameter); break,}
				when("data")		{ $result = retrieveText($hash,"conditions","\n"); break; }
				when("stations")	{ $result = retrieveText($hash,"conditions2","\n"); break; }
				default				{ $usage  = "get <name> list <parameter>"; return $usage; }
			}
			break;
			}

		when("alerts"){
			if($parameter =~ y/0-9// == length($parameter)){
				while ( my( $key, $val ) = each %capCellHash ) {
					push @datensatz,$val if $key =~ m/^$parameter/;
				}
#				push @datensatz,$capCellHash{$parameter};
			} else {
				push @datensatz,$capCityHash{$parameter};
			}
			CommandDeleteReading(undef, "$name a_.*");
			if($datensatz[0]){
				my $anum = 0;
				foreach(@datensatz) {
					decodeCAPData($hash,$_,$anum);
					$anum++;
				};
				readingsSingleUpdate($hash,'a_count',$anum,1);
			} else {
				$result = "Keine Warnmeldung für die gesuchte Region vorhanden.";
			}
            my $_gdsAll		= AttrVal($name,"gdsAll", 0);
            my $_gdsDebug	= AttrVal($name,"gdsDebug", 0);
			readingsSingleUpdate($hash,'_lastAlertCheck','see timestamp ->',1) if($_gdsAll || $_gdsDebug);
			break;
			}

		when("headlines"){
			$result = gdsHeadlines($name);
			break;
			}

		when("conditions"){
			retrieveConditions($hash, "g", @a);
			break;
			}

		when("rereadcfg"){
			eval {
				retrieveFile($hash,"alerts",undef,undef);
			};
			eval {
				retrieveFile($hash,"conditions",undef,undef);
			}; 
			initDropdownLists($hash);
			eval {
				getListForecastStations($hash);
			};
			break;
			}

		when("warnings"){
			my $vhdl;
			$result =	"     VHDL30 = current          |     VHDL31 = weekend or holiday\n".
						"     VHDL32 = preliminary      |     VHDL33 = cancel VHDL32\n".
						sepLine(31)."+".sepLine(38);
			for ($vhdl=30; $vhdl <=33; $vhdl++){
				(undef, $found) = retrieveFile($hash, $command, $parameter, $vhdl);
				if($found){
					$result .= retrieveText($hash, "warnings", "");
					$result .= "\n".sepLine(70);
				}
			}
			$result .= "\n\n";
			break;
			}

		when("forecasts"){
			$parameter = ucfirst($parameter);
			$result = sepLine(67)."\n";
			(undef, $found) = retrieveFile($hash,$command,$parameter,undef);
			if($found){
					$result .= retrieveText($hash, $command, "\n");
			}
			$result .= "\n".sepLine(67)."\n";
			break;
			}

		default { return $usage; };
	}
	return $result;
}

sub GDS_Attr(@){
	my @a = @_;
	my $hash = $defs{$a[1]};
	my ($cmd, $name, $attrName, $attrValue) = @a;

	given($attrName){
		when("gdsDebug"){
			CommandDeleteReading(undef, "$name _dF.*") if($attrValue != 1 || $cmd eq 'delete');
			break;
			}
 		when("gdsSetCond"){
            GDS_Set($hash,undef,'conditions',$attrValue) if($init_done && $cmd eq 'set');
            break;
            }
 		when("gdsSetForecast"){
            GDS_Set($hash,undef,'forecasts',$attrValue) if($init_done && $cmd eq 'set');
            break;
 			}
 		when("gdsHideFiles"){
 		    my $hR = AttrVal($FW_wname,'hiddenroom','');
 		    $hR =~ s/\,GDS.Files//g;
			if($attrValue) {
	 		    $hR .= "," if(length($hR));
 			    $hR .= "GDS Files";
			}
			CommandAttr(undef,"$FW_wname hiddenroom $hR");
 			break;
 			}
		default {$attr{$name}{$attrName} = $attrValue;}
	}
	if(IsDisabled($name)) {
		readingsSingleUpdate($hash, 'state', 'disabled', 0);
	} else {
		readingsSingleUpdate($hash, 'state', 'active', 0);
	}
	return;
}

sub GDS_GetUpdate($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $next;
  
	my $interval            = $hash->{helper}{INTERVAL};
	my $forcastsStationName = ReadingsVal($name, "fc_stationName", undef);
	my $condStationName     = ReadingsVal($name, "c_stationName", undef);

	if(IsDisabled($name)) {
    	readingsSingleUpdate($hash, 'state', 'disabled', 0);
		Log3 ($name, 2, "GDS $name is disabled, data update cancelled.");
	} else {
		readingsSingleUpdate($hash, 'state', 'active', 0);
		if($condStationName) {
			my @a;
			push @a, undef;
			push @a, undef;
			push @a, ReadingsVal($name, "c_stationName", "");
			retrieveConditions($hash, "c", @a);
		}
		if($forcastsStationName) {
			my @a;
			push @a, undef;
			push @a, undef;
			push @a, $forcastsStationName;
			retrieveForecasts($hash, "fc", @a);    
		}
	}
	# schedule next update
	$next = gettimeofday() + $interval;
	readingsSingleUpdate($hash, "_nextUpdate", localtime($next), 1);
	InternalTimer($next, "GDS_GetUpdate", $hash, 1);

	return 1;
}

###################################################################################################
#
#	FWEXT implementation
#
###################################################################################################

sub GDS_addExtension($$$) {
    my ($func,$link,$friendlyname)= @_;
  
    my $url = "/" . $link;
    Log3(undef,4,"Register gds webservice in FWEXT");
    $data{FWEXT}{$url}{FUNC} = $func;
    $data{FWEXT}{$url}{LINK} = "+$link";
    $data{FWEXT}{$url}{NAME} = $friendlyname;
    $data{FWEXT}{$url}{FORKABLE} = 0;
}

sub GDS_CGI {
  my ($request) = @_;
  my ($name,$ext)= GDS_splitRequest($request);
  if(defined($name)) {
     my $filename= "$tempDir/$name.$ext";
     my $MIMEtype= filename2MIMEType($filename);
     my @contents;
     if(open(INPUTFILE, $filename)) {
       binmode(INPUTFILE);
       @contents= <INPUTFILE>;
       close(INPUTFILE);
       return("$MIMEtype; charset=utf-8", join("", @contents));
     } else {
       return("text/plain; charset=utf-8", "File not found: $filename");
     }
  } else {
    return GDS_Overview();
  }
}

sub GDS_splitRequest($) {
  my ($request) = @_;

  if($request =~ /^.*\/gds$/) {
    # http://localhost:8083/fhem/gds2
    return (undef,undef); # name, ext
  } else {
    my $call= $request;
    $call =~ s/^.*\/gds\/([^\/]*)$/$1/;
    my $name= $call;
    $name =~ s/^(.*)\.(jpg)$/$1/;
    my $ext= $call;
    $ext =~ s/^$name\.(.*)$/$1/;
    return ($name,$ext);
  }
}

sub GDS_Overview {
  my ($name, $url);
  my $html= GDS_HTMLHead("GDS Overview") . "<body>\n\n";
  foreach my $def (sort keys %defs) {
     if($defs{$def}{TYPE} eq "GDS") {
        $name= $defs{$def}{NAME};
        $url   = GDS_getURL();
        $html .= "$name<br>\n<ul>\n";
        $html .= "<a href=\"$url/gds/$name\_conditionsmap.jpg\" target=\"_blank\">Aktuelle Wetterkarte: Wetterlage</a><br/>\n";
        $html .= "<a href=\"$url/gds/$name\_forecastsmap.jpg\" target=\"_blank\">Aktuelle Wetterkarte: Vorhersage</a><br/>\n";
        $html .= "<a href=\"$url/gds/$name\_warningsmap.jpg\" target=\"_blank\">Aktuelle Wetterkarte: Warnungen</a><br/>\n";
        $html .= "<a href=\"$url/gds/$name\_radarmap.jpg\" target=\"_blank\">Aktuelle Wetterkarte: Radarkarte</a><br/>\n";
        $html.= "</ul>\n\n";
    }
  }
  $html.="</body>\n" . GDS_HTMLTail();

  return ("text/html; charset=utf-8", $html);
}

sub GDS_HTMLHead($) {
  my ($title) = @_;
  my $doctype= '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">';
  my $xmlns= 'xmlns="http://www.w3.org/1999/xhtml"';
  my $code= "$doctype\n<html $xmlns>\n<head>\n<title>$title</title>\n</head>\n";
  return $code;
}

sub GDS_HTMLTail {
  return "</html>";
}

sub GDS_getURL {
  my $proto = (AttrVal($FW_wname, 'HTTPS', 0) == 1) ? 'https' : 'http';
  return $proto."://$FW_httpheader{Host}$FW_ME"; #".$FW_ME;
}

###################################################################################################
#
#	Tools
#
###################################################################################################

sub setHelp(){
	return	"Use one of the following commands:\n".
			sepLine(35)."\n".
			"set <name> clear alerts|all\n".
			"set <name> conditions <stationName>\n".
			"set <name> forecasts <regionName>/<stationName>\n".
			"set <name> help\n".
			"set <name> rereadcfg\n".
			"set <name> update\n";
}

sub getHelp(){
	return	"Use one of the following commands:\n".
			sepLine(35)."\n".
			"get <name> alerts <region>\n".
			"get <name> conditions <stationName>\n".
			"get <name> forecasts <regionName>\n".
			"get <name> help\n".
			"get <name> list capstations|stations|data\n".
			"get <name> rereadcfg\n".
			"get <name> warnings <region>\n";
}

sub retrieveText($$$) {
   my ($hash, $fileName, $separator) = @_;
   my $name = $hash->{NAME};
   my ($err,@a);
   
   given ($fileName) {
      when ("conditions2") {
         # get conditions stations list
         $fileName = $tempDir.$name."_conditions";
         ($err,@a) = FileRead({FileName=>$fileName,ForceType=>"file" });
         return "GDS error reading $fileName" if($err);
         @a = map (substr(latin1ToUtf8($_),0,19), @a);    
         unshift(@a, "Use one of the following stations:", sepLine(40));
      }
      default {
         $fileName = $tempDir.$name."_$fileName";
         ($err,@a) = FileRead({FileName=>$fileName,ForceType=>"file" });
         return "GDS error reading $fileName" if($err);
         @a = map (latin1ToUtf8($_), @a);
      }
   }

   return join($separator, @a);
}

sub getListCapStations($$){
	my ($hash, $command) = @_;
	my $name = $hash->{NAME};
	my (%capHash, $file, @columns, $key, $cList, $count);

	$file = $tempDir.'capstations.csv';
	return "GDS error: $file not found." unless(-e $file);

	if (!defined($cList)) {
		# CSV öffnen und parsen
		my ($err,@a) = FileRead({FileName=>$file,ForceType=>"file" });
		return "GDS error reading $file" if($err);

		foreach my $l (@a) {
			next if (substr($l,0,1) eq '#');
			@columns = split(";",$l);
			$capHash{latin1ToUtf8($columns[4])} = $columns[0];
		}

		# Ausgabe sortieren und zusammenstellen
		foreach $key (sort keys %capHash) {
			$cList .= $capHash{$key}."\t".$key."\n";
		}
	}
	return $cList;
}

sub getListStations($){
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my ($line, $liste);

    my $fileName = $tempDir.$name."_conditions";
    return unless -e $fileName;
    my $filesize = -s $fileName;
    return unless $filesize != 0;

    my ($err,@a) = FileRead({FileName=>$fileName,ForceType=>"file" });
    return "GDS error reading $fileName" if($err);
    @a = map (trim(substr(latin1ToUtf8($_),0,19)), @a);    

	# delete header lines 
	splice(@a, 0, 6);
	# delete legend 
	splice(@a, _first_index("Höhe",@a)-1);
	@a = sort(@a);

	$sList = join(",", @a);
	$sList =~ s/\s+,/,/g; # replace multiple spaces followed by comma with comma
	$sList =~ s/\s/_/g;   # replace spaces in stationName with underscore for list in frontende
	return;
}

sub buildCAPList($){
	my ($hash) = @_;
	my $name = $hash->{NAME};

	%capCityHash	= ();
	%capCellHash	= ();
	$alertsXml		= undef;
    $aList          = "please_use_rereadcfg_first";

	my $xml			= new XML::Simple;
	my $area		= 0;
	my $record		= 0;
	my $n			= 0;
	my ($capCity, $capCell, $capEvent, $capEvt, @a);
    my $destinationDirectory = $tempDir.$name."_alerts.dir";
    
    # make XML array and analyze data
    my ($countInfo,$cF) = mergeCapFile($hash);
    eval	{	
	  $alertsXml = $xml->XMLin($cF, KeyAttr => {}, ForceArray => [ 'info', 'eventCode', 'area', 'geocode' ]);
    };
    if ($@) {
       Log3($name,1,'GDS: error analyzing alerts XML:'.$@);
       return (undef,undef);
    }

    # analyze entries based on info and area array
    # array elements are determined by $info and $area
    #
    for (my $info=0; $info<=$countInfo;$info++) {
       $area = 0;
       while(1){
          $capCity  = $alertsXml->{info}[$info]{area}[$area]{areaDesc};
          $capEvent = $alertsXml->{info}[$info]{event};
          last unless $capCity;
          $capCell  = findCAPWarnCellId($info, $area);
          $n        = 100*$info+$area;
          $capCity  = latin1ToUtf8($capCity.' '.$capEvent);
          push @a, $capCity;
          $capCity =~ s/\s/_/g;
          $capCityHash{$capCity} = $n;
          $capCellHash{"$capCell$n"} = $n;
          $area++;
          $record++;
          $capCity = undef;
       }
    }

	@a = sort(@a);
    $aList = undef;
	$aList = join(",", @a);
	$aList =~ s/\s/_/g;
	$aList = "No_alerts_published!" if !$record;
    return;
}

sub decodeCAPData($$$){
	my ($hash, $datensatz, $anum) = @_;
	my $name		= $hash->{NAME};
	my $info		= int($datensatz/100);
	my $area		= $datensatz-$info*100;

	my (%readings, @dummy, $i, $k, $n, $v, $t);

	my $_gdsAll		= AttrVal($name,"gdsAll", 0);
	my $_gdsDebug	= AttrVal($name,"gdsDebug", 0);
	my $_gdsLong	= AttrVal($name,"gdsLong", 0);
	my $_gdsPolygon	= AttrVal($name,"gdsPolygon", 0);

	Log3($name, 4, "GDS $name: Decoding CAP record #".$datensatz);

# topLevel informations
	@dummy = split(/\./, $alertsXml->{identifier});

	$readings{"a_".$anum."_identifier"}		= $alertsXml->{identifier}	if($_gdsAll || $_gdsDebug);
	$readings{"a_".$anum."_idPublisher"}	= $dummy[5]					if($_gdsAll);
	$readings{"a_".$anum."_idSysten"}		= $dummy[6]					if($_gdsAll);
	$readings{"a_".$anum."_idTimeStamp"}	= $dummy[7]					if($_gdsAll);
	$readings{"a_".$anum."_idIndex"}		= $dummy[8]					if($_gdsAll);
	$readings{"a_".$anum."_sent"}			= $alertsXml->{sent}[0];
	$readings{"a_".$anum."_status"}			= $alertsXml->{status}[0];
	$readings{"a_".$anum."_msgType"}		= $alertsXml->{msgType}[0];
# infoSet informations
	$readings{"a_".$anum."_language"}		= $alertsXml->{info}[$info]{language}		if($_gdsAll);
	$readings{"a_".$anum."_category"}		= $alertsXml->{info}[$info]{category};
	$readings{"a_".$anum."_event"}			= $alertsXml->{info}[$info]{event};
	$readings{"a_".$anum."_responseType"}	= $alertsXml->{info}[$info]{responseType};
	$readings{"a_".$anum."_urgency"}		= $alertsXml->{info}[$info]{urgency}		if($_gdsAll);
	$readings{"a_".$anum."_severity"}		= $alertsXml->{info}[$info]{severity}		if($_gdsAll);
	$readings{"a_".$anum."_certainty"}		= $alertsXml->{info}[$info]{certainty}		if($_gdsAll);

# eventCode informations
# loop through array
	$i = 0;
	while(1){
		($n, $v) = (undef, undef);
		$n = $alertsXml->{info}[$info]{eventCode}[$i]{valueName};
		if(!$n) {last;}
		$n = "a_".$anum."_eventCode_".$n;
		$v = $alertsXml->{info}[$info]{eventCode}[$i]{value};
		$readings{$n} .= $v." " if($v);
		$i++;
	}

# time/validity informations
	$readings{"a_".$anum."_effective"}		= $alertsXml->{info}[$info]{effective}					if($_gdsAll);
	$readings{"a_".$anum."_onset"}			= $alertsXml->{info}[$info]{onset};
	$readings{"a_".$anum."_expires"}		= $alertsXml->{info}[$info]{expires};
	$readings{"a_".$anum."_valid"}			= checkCAPValid($readings{"a_".$anum."_onset"},$readings{"a_".$anum."_expires"});
	$readings{"a_".$anum."_onset_local"}	= capTrans($readings{"a_".$anum."_onset"});
	$readings{"a_".$anum."_expires_local"}	= capTrans($readings{"a_".$anum."_expires"}) 
	         if(defined($alertsXml->{info}[$info]{expires}));
	$readings{"a_".$anum."_sent_local"}		= capTrans($readings{"a_".$anum."_sent"});

	$readings{a_valid} = ReadingsVal($name,'a_valid',0) || $readings{"a_".$anum."_valid"};

# text informations
	$readings{"a_".$anum."_headline"}		= $alertsXml->{info}[$info]{headline};
	$readings{"a_".$anum."_description"}	= $alertsXml->{info}[$info]{description}				if($_gdsAll || $_gdsLong);
	$readings{"a_".$anum."_instruction"}	= $alertsXml->{info}[$info]{instruction} 				if($readings{"a_".$anum."_responseType"} eq "Prepare" 
																						&& ($_gdsAll || $_gdsLong));

# area informations
	$readings{"a_".$anum."_areaDesc"} 		=  $alertsXml->{info}[$info]{area}[$area]{areaDesc};
	$readings{"a_".$anum."_areaPolygon"}	=  $alertsXml->{info}[$info]{area}[$area]{polygon}		if($_gdsAll || $_gdsPolygon);

# area geocode informations
# loop through array
	$i = 0;
	while(1){
		($n, $v) = (undef, undef);
		$n = $alertsXml->{info}[$info]{area}[$area]{geocode}[$i]{valueName};
		if(!$n) {last;}
		$n = "a_".$anum."_geoCode_".$n;
		$v = $alertsXml->{info}[$info]{area}[$area]{geocode}[$i]{value};
		$readings{$n} .= $v." " if($v);
		$i++;
	}

	$readings{"a_".$anum."_altitude"}		= $alertsXml->{info}[$info]{area}[$area]{altitude}		if($_gdsAll);
	$readings{"a_".$anum."_ceiling"}		= $alertsXml->{info}[$info]{area}[$area]{ceiling}		if($_gdsAll);

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "_dataSource", "Quelle: Deutscher Wetterdienst");
	while(($k, $v) = each %readings){
		# skip update if no valid data is available
        next unless(defined($v));
		readingsBulkUpdate($hash, $k, latin1ToUtf8($v)); 
	}
#	readingsEndUpdate($hash, 1);

	# convert color value to hex
	eval { readingsBulkUpdate($hash, 'a_'.$anum.'_eventCode_AREA_COLOR_hex', 
	       _rgbd2h(ReadingsVal($name, 'a_'.$anum.'_eventCode_AREA_COLOR', '')));};
	readingsEndUpdate($hash, 1);

	return;
}

# sub checkCAPValid($$){
# 	my ($onset,$expires) = @_;
# 	my $valid = 0;
# 	my $offset = _calctz(time,localtime(time))*3600; # used from 99_SUNRISE_EL
#     my $t = (time - $offset);
# 
# 	$onset =~ s/T/ /;
# 	$onset =~ s/\+/ \+/;
# 	$onset = time_str2num($onset);
# 
# 	$expires =~ s/T/ /;
# 	$expires =~ s/\+/ \+/;
# 	$expires = time_str2num($expires);
# 
# 	$valid = 1 if($onset lt $t && $expires gt $t);
# 	return $valid;
# }

sub checkCAPValid($$;$$){
	my ($onset,$expires,$t,$tmax) = @_;
	my $valid = 0;
  
	$t = time() if (!defined($t));
	my $offset = _calctz($t,localtime($t))*3600; # used from 99_SUNRISE_EL
	$t -= $offset;
	$tmax -= $offset if (defined($tmax));

	$onset =~ s/T/ /;
	$onset =~ s/\+/ \+/;
	$onset = time_str2num($onset);

	$expires =~ s/T/ /;
	$expires =~ s/\+/ \+/;
	$expires = time_str2num($expires);

	if (defined($tmax)) {  
		$valid = 1 if($tmax ge $onset && $t lt $expires);
	} else {
		$valid = 1 if($onset lt $t && $expires gt $t);
	}
	return $valid;
}

sub capTrans($) {
	my ($t) = @_;
	my $valid = 0;
	my $offset = _calctz(time,localtime(time))*3600; # used from 99_SUNRISE_EL
	$t =~ s/T/ /;
	$t =~ s/\+/ \+/;
	$t = time_str2num($t);
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime($t+$offset);
	$mon  += 1;
	$year += 1900;
	$t = sprintf "%02s.%02s.%02s %02s:%02s:%02s", $mday, $mon, $year, $hour, $min, $sec;
	return $t;
}

sub findCAPWarnCellId($$){
	my ($info, $area) = @_;
	my $i = 0;
	while($i < 100){
		if($alertsXml->{info}[$info]{area}[$area]{geocode}[$i]{valueName} eq "WARNCELLID"){
			return $alertsXml->{info}[$info]{area}[$area]{geocode}[$i]{value};
			last;
		}
		$i++;
	}
}

sub retrieveConditions($$@){
	my ($hash, $prefix, @a) = @_;
	my $name		= $hash->{NAME};
	(my $myStation	= utf8ToLatin1($a[2])) =~ s/_/ /g; # replace underscore in stationName by space
	my $searchLen	= length($myStation);

	my ($line, $item, %pos, %alignment, %wx, %cread, $k, $v);

	Log3($name, 4, "GDS $name: Retrieving conditions data");
	retrieveFile($hash,"conditions",undef,undef);
	
    my $fileName = $tempDir.$name."_conditions";
    my ($err,@file) = FileRead({FileName=>$fileName,ForceType=>"file" });
    return "GDS error reading $fileName" if($err);

    foreach my $l (@file) {
        $line = $l;                 # save line for further use
 		if ($l =~ /Station/) {		# Header line... find out data positions
 			@a = split(/\s+/, $l);
 			foreach $item (@a) {
 				$pos{$item} = index($line, $item);
 			}
 		}
 		if (index(substr(lc($line),0,$searchLen), substr(lc($myStation),0,$searchLen)) != -1) { last; }
    }	

	%alignment = ("Station" => "l", "H\xF6he" => "r", "Luftd." => "r", "TT" => "r", "Tn12" => "r", "Tx12" => "r", 
	"Tmin" => "r", "Tmax" => "r", "Tg24" => "r", "Tn24" => "r", "Tm24" => "r", "Tx24" => "r", "SSS24" => "r", "SGLB24" => "r", 
	"RR1" => "r", "RR12" => "r", "RR24" => "r", "SSS" => "r", "DD" => "r", "FF" => "r", "FX" => "r", "Wetter/Wolken" => "l", "B\xF6en" => "l");
	
	foreach $item (@a) {
		Log3($hash, 4, "conditions item: $item");
		$wx{$item} = &readItem($line, $pos{$item}, $alignment{$item}, $item);
	}

	%cread = ();
	$cread{"_dataSource"} = "Quelle: Deutscher Wetterdienst";

	if(length($wx{"Station"})){
		$cread{$prefix."_stationName"}	= $wx{"Station"};
		$cread{$prefix."_altitude"}			= $wx{"H\xF6he"};
		$cread{$prefix."_pressure-nn"}	= $wx{"Luftd."};
		$cread{$prefix."_temperature"}	= $wx{"TT"};
		$cread{$prefix."_tMinAir12"}		= $wx{"Tn12"};
		$cread{$prefix."_tMaxAir12"}		= $wx{"Tx12"};
		$cread{$prefix."_tMinGrnd24"}		= $wx{"Tg24"};
		$cread{$prefix."_tMinAir24"}		= $wx{"Tn24"};
		$cread{$prefix."_tAvgAir24"}		= $wx{"Tm24"};
		$cread{$prefix."_tMaxAir24"}		= $wx{"Tx24"};
		$cread{$prefix."_tempMin"}			= $wx{"Tmin"};
		$cread{$prefix."_tempMax"}			= $wx{"Tmax"};
		$cread{$prefix."_rain1h"}				= $wx{"RR1"};
		$cread{$prefix."_rain12h"}			= $wx{"RR12"};
		$cread{$prefix."_rain24h"}			= $wx{"RR24"};
		$cread{$prefix."_snow"}					= $wx{"SSS"};
		$cread{$prefix."_sunshine"}			= $wx{"SSS24"};
		$cread{$prefix."_solar"}				= $wx{"SGLB24"};
		$cread{$prefix."_windDir"}			= $wx{"DD"};
		$cread{$prefix."_windSpeed"}		= $wx{"FF"};
		$cread{$prefix."_windPeak"}			= $wx{"FX"};
		$cread{$prefix."_weather"}			= $wx{"Wetter\/Wolken"};
		$cread{$prefix."_windGust"}			= $wx{"B\xF6en"};
	} else {
		$cread{$prefix."_stationName"}	= "unknown: $myStation";
	}

	readingsBeginUpdate($hash);
	while (($k, $v) = each %cread) {
		# skip update if no valid data is available
        unless(defined($v))      {delete($defs{$name}{READINGS}{$k}); next;}
		if($v =~ m/^--/)         {delete($defs{$name}{READINGS}{$k}); next;};
        unless(length(trim($v))) {delete($defs{$name}{READINGS}{$k}); next;};
		readingsBulkUpdate($hash, $k, latin1ToUtf8($v)); 
	}
	readingsEndUpdate($hash, 1);

	return ;
}

sub retrieveFile($$$$){
    #
    # request = type, e.g. alerts, conditions, warnings
    # parameter = additional selector, e.g. Bundesland
    #
	my ($hash, $request, $parameter, $parameter2) = @_;
	$hash->{helper}{request}    = $request;
	$hash->{helper}{parameter}  = $parameter;
	$hash->{helper}{parameter2} = $parameter2;
	BlockingCall('_retrieveFile',$hash,undef,60,undef,undef);
	delete $hash->{helper}{request};
	delete $hash->{helper}{parameter};
	delete $hash->{helper}{parameter2};

    return(undef,undef);
}

sub _retrieveFile($){
	my ($hash) = @_;
	my $name		= $hash->{NAME};
	my $user		= $hash->{helper}{USER};
	my $pass		= $hash->{helper}{PASS};
	my $host		= $hash->{helper}{URL};
    my $request		= $hash->{helper}{request};
	my $parameter   = $hash->{helper}{parameter};
	my $parameter2  = $hash->{helper}{parameter2};
	
	my $proxyName	= AttrVal($name, "gdsProxyName", "");
	my $proxyType	= AttrVal($name, "gdsProxyType", "");
	my $passive		= AttrVal($name, "gdsPassiveFtp", 0);
	my $debug		= AttrVal($name, "gdsDebug",0);

	my ($dwd, $dir, $ftp, @files, $dataFile, $targetFile, $found, $readingName);
	
	my $urlString =	"ftp://$user:$pass\@".$host."/";

	given($request){

		when("capstations"){
			$dir = "gds/help/";
			$dwd = "legend_warnings_CAP_WarnCellsID.csv";
			$targetFile = $tempDir.$request.".csv";
			break;
		}

		when("conditionsmap"){
			$dir = "gds/specials/observations/maps/germany/";
			$dwd = $parameter."*";
			$targetFile = $tempDir.$name."_".$request.".jpg";
			break;
		}

		when("forecastsmap"){
			$dir = "gds/specials/forecasts/maps/germany/";
			$dwd = $parameter."*";
			$targetFile = $tempDir.$name."_".$request.".jpg";
			break;
		}

		when("warningsmap"){
			if(length($parameter) != 2){
				$parameter = $bula2bulaShort{lc($parameter)};
			}
			$dwd = "Schilder".$dwd2Dir{$bulaShort2dwd{lc($parameter)}}.".jpg";
			$dir = "gds/specials/alerts/maps/";
			$targetFile = $tempDir.$name."_".$request.".jpg";
			break;
		}

		when("radarmap"){
			$dir = "gds/specials/radar/".$parameter2;
			$dwd = "Webradar_".$parameter."*";
			$targetFile = $tempDir.$name."_".$request.".jpg";
			break;
		}

		when("alerts"){
			$dir = "gds/specials/alerts/cap/GER/status/";
			$dwd = "Z_CAP*";
            my $targetDir = $tempDir.$name."_alerts.dir";
            mkdir $targetDir unless -d $targetDir;
			$targetFile = "$targetDir/$name"."_alerts.zip";
			break;
			}

		when("conditions"){
			$dir = "gds/specials/observations/tables/germany/";
			$dwd = "*";
			$targetFile = $tempDir.$name."_".$request;
			break;
			}

		when("forecasts"){
			$dir = "gds/specials/forecasts/tables/germany/";
			$dwd = "Daten_".$parameter;
			$targetFile = $tempDir.$name."_".$request;
			break;
			}

		when("warnings"){
			if(length($parameter) != 2){
				$parameter = $bula2bulaShort{lc($parameter)};
			}
			$dwd = $bulaShort2dwd{lc($parameter)};
			$dir = $dwd2Dir{$dwd};
			$dwd = "VHDL".$parameter2."_".$dwd."*";
			$dir = "gds/specials/warnings/".$dir."/";
			$targetFile = $tempDir.$name."_".$request;
			break;
			}
	}

	# delete old file 
	eval{ unlink $targetFile; };
 
	Log3($name, 4, "GDS $name: searching for $dir".$dwd." on DWD server");
	$urlString .= $dir;

	$found = 0;
	eval {
		$ftp = Net::FTP->new(	$host,
								Debug        => 0,
								Timeout      => 10,
								Passive      => $passive,
								FirewallType => $proxyType,
								Firewall     => $proxyName);
		if(defined($ftp)){
			Log3($name, 4, "GDS $name: ftp connection established.");
			$ftp->login($user, $pass);
			$ftp->binary;
			$ftp->cwd("$dir");
			@files = undef;
			@files = $ftp->ls($dwd);
			if(@files){
				Log3($name, 4, "GDS $name: filelist found.");
				$found = 1;
				@files = sort(@files);
				$dataFile = $files[-1];
				$urlString .= $dataFile;
				Log3($name, 5, "GDS $name: retrieving $dataFile");
				$ftp->get($dataFile,$targetFile);
				my $s = -s $targetFile;
                Log3($name, 5, "GDS: ftp transferred $s bytes");
			} else { 
				Log3($name, 4, "GDS $name: filelist not found.");
				$found = 0;
			}
			$ftp->quit;
		}
		Log3($name, 4, "GDS $name: updating readings.");
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "_dataSource",		"Quelle: Deutscher Wetterdienst");
		readingsBulkUpdate($hash, "_dF_".$request, $dataFile) if(AttrVal($name, "gdsDebug", 0));
		readingsEndUpdate($hash, 0);
	};
	return ($hash);
}

sub readItem {
	my ($line, $pos, $align, $item)  = @_;
	my $x;
	
	if ($align eq "l") {
		$x = substr($line, $pos);
		$x =~ s/  .+$//g;	# after two spaces => next field
	}
	if ($align eq "r") {
		$pos += length($item);
		$x = substr($line, 0, $pos);
		$x =~ s/^.+  //g;	# remove all before the item
	}
	return $x;
}

sub sepLine($) {
	my ($len) = @_;
	my ($output, $i);
	for ($i=0; $i<$len; $i++) { $output .= "-"; }
	return $output;
}

sub _rgbd2h($) {
	my ($input) = @_;
	my @a = split(" ", $input);
	my $output = sprintf( "%02x%02x%02x", $a[0],$a[1],$a[2]);
	return $output;
}

sub _first_index ($@) {
    my ($reg,@a) = @_;
    my $i        = 0;
    foreach my $l (@a) {
        return $i if ($l =~ m/$reg/);
        $i++;
    }
    return -1;
}

sub fillMappingTables($){
    my ($hash) = @_;

    $tempDir  = "/tmp/";
    $aList    = "please_use_rereadcfg_first";
	$sList    = $aList;
 	$fList    = $aList;

	retrieveFile($hash,"capstations",undef,undef);

	$bulaList =	"Baden-Württemberg,Bayern,Berlin,Brandenburg,Bremen,".
				"Hamburg,Hessen,Mecklenburg-Vorpommern,Niedersachsen,".
				"Nordrhein-Westfalen,Rheinland-Pfalz,Saarland,Sachsen,".
				"Sachsen-Anhalt,Schleswig-Holstein,Thüringen";

	$cmapList =	"Deutschland,Mitte,Nordost,Nordwest,Ost,Suedost,Suedwest,West";

	%rmapList = (
	Deutschland	=> "",
	Mitte		=> "central/",
	Nordost		=> "northeast/",
	Nordwest	=> "northwest/",
	Ost			=> "east/",
	Suedost		=> "southeast/",
	Suedwest	=> "southwest/",
	West		=> "west/");

	$fmapList =	"Deutschland_heute_frueh,Deutschland_heute_mittag,Deutschland_heute_spaet,Deutschland_heute_nacht,".
				"Deutschland_morgen_frueh,Deutschland_morgen_spaet,".
				"Deutschland_ueberm_frueh,Deutschland_ueberm_spaet,".
				"Deutschland_tag4_frueh,Deutschland_tag4_spaet,".
				"Mitte_heute_frueh,Mitte_heute_mittag,Mitte_heute_spaet,Mitte_heute_nacht,".
				"Mitte_morgen_frueh,Mitte_morgen_spaet,".
				"Mitte_ueberm_frueh,Mitte_ueberm_spaet,".
				"Mitte_tag4_frueh,Mitte_tag4_spaet,".
				"Nordost_heute_frueh,Nordost_heute_mittag,Nordost_heute_spaet,Nordost_heute_nacht,".
				"Nordost_morgen_frueh,Nordost_morgen_spaet,".
				"Nordost_ueberm_frueh,Nordost_ueberm_spaet,".
				"Nordost_tag4_frueh,Nordost_tag4_spaet,".
				"Nordwest_heute_frueh,Nordwest_heute_mittag,Nordwest_heute_spaet,Nordwest_heute_nacht,".
				"Nordwest_morgen_frueh,Nordwest_morgen_spaet,".
				"Nordwest_ueberm_frueh,Nordwest_ueberm_spaet,".
				"Nordwest_tag4_frueh,Nordwest_tag4_spaet,".
				"Ost_heute_frueh,Ost_heute_mittag,Ost_heute_spaet,Ost_heute_nacht,".
				"Ost_morgen_frueh,Ost_morgen_spaet,".
				"Ost_ueberm_frueh,Ost_ueberm_spaet,".
				"Ost_tag4_frueh,Ost_tag4_spaet,".
				"Suedost_heute_frueh,Suedost_heute_mittag,Suedost_heute_spaet,Suedost_heute_nacht,".
				"Suedost_morgen_frueh,Suedost_morgen_spaet,".
				"Suedost_ueberm_frueh,Suedost_ueberm_spaet,".
				"Suedost_tag4_frueh,Suedost_tag4_spaet,".
				"Suedwest_heute_frueh,Suedwest_heute_mittag,Suedwest_heute_spaet,Suedwest_heute_nacht,".
				"Suedwest_morgen_frueh,Suedwest_morgen_spaet,".
				"Suedwest_ueberm_frueh,Suedwest_ueberm_spaet,".
				"Suedwest_tag4_frueh,Suedwest_tag4_spaet,".
				"West_heute_frueh,West_heute_mittag,West_heute_spaet,West_heute_nacht,".
				"West_morgen_frueh,West_morgen_spaet,".
				"West_ueberm_frueh,West_ueberm_spaet,".
				"West_tag4_frueh,West_tag4_spaet";

	$fcmapList =	"Deutschland_frueh,Deutschland_mittag,Deutschland_spaet,Deutschland_nacht,".
				"Deutschland_morgen_frueh,Deutschland_morgen_spaet,".
				"Deutschland_uebermorgen_frueh,Deutschland_uebermorgen_spaet,".
				"Deutschland_Tag4_frueh,Deutschland_Tag4_spaet,".
				"Mitte_frueh,Mitte_mittag,Mitte_spaet,Mitte_nacht,".
				"Mitte_morgen_frueh,Mitte_morgen_spaet,".
				"Mitte_uebermorgen_frueh,Mitte_uebermorgen_spaet,".
				"Mitte_Tag4_frueh,Mitte_Tag4_spaet,".
				"Nordost_frueh,Nordost_mittag,Nordost_spaet,Nordost_nacht,".
				"Nordost_morgen_frueh,Nordost_morgen_spaet,".
				"Nordost_uebermorgen_frueh,Nordost_uebermorgen_spaet,".
				"Nordost_Tag4_frueh,Nordost_Tag4_spaet,".
				"Nordwest_frueh,Nordwest_mittag,Nordwest_spaet,Nordwest_nacht,".
				"Nordwest_morgen_frueh,Nordwest_morgen_spaet,".
				"Nordwest_uebermorgen_frueh,Nordwest_uebermorgen_spaet,".
				"Nordwest_Tag4_frueh,Nordwest_Tag4_spaet,".
				"Ost_frueh,Ost_mittag,Ost_spaet,Ost_nacht,".
				"Ost_morgen_frueh,Ost_morgen_spaet,".
				"Ost_uebermorgen_frueh,Ost_uebermorgen_spaet,".
				"Ost_Tag4_frueh,Ost_Tag4_spaet,".
				"Suedost_frueh,Suedost_mittag,Suedost_spaet,Suedost_nacht,".
				"Suedost_morgen_frueh,Suedost_morgen_spaet,".
				"Suedost_uebermorgen_frueh,Suedost_uebermorgen_spaet,".
				"Suedost_Tag4_frueh,Suedost_Tag4_spaet,".
				"Suedwest_frueh,Suedwest_mittag,Suedwest_spaet,Suedwest_nacht,".
				"Suedwest_morgen_frueh,Suedwest_morgen_spaet,".
				"Suedwest_uebermorgen_frueh,Suedwest_uebermorgen_spaet,".
				"Suedwest_Tag4_frueh,Suedwest_Tag4_spaet,".
				"West_frueh,West_mittag,West_spaet,West_nacht,".
				"West_morgen_frueh,West_morgen_spaet,".
				"West_uebermorgen_frueh,West_uebermorgen_spaet,".
				"West_Tag4_frueh,West_Tag4_spaet";

#
# Bundesländer den entsprechenden Dienststellen zuordnen
#
	%bula2bulaShort = (
	"baden-württemberg"			=> "bw",
	"bayern"					=> "by",
	"berlin"					=> "be",
	"brandenburg"				=> "bb",
	"bremen"					=> "hb",
	"hamburg"					=> "hh",
	"hessen" 					=> "he",
	"mecklenburg-vorpommern"	=> "mv",
	"niedersachsen"				=> "ni",
	"nordrhein-westfalen"		=> "nw",
	"rheinland-pfalz"			=> "rp",
	"saarland"					=> "sl",
	"sachsen"					=> "sn",
	"sachsen-anhalt"			=> "st",
	"schleswig-holstein"		=> "sh",
	"thüringen"					=> "th",
	"deutschland"				=> "xde",
	"bodensee"					=> "xbo" );

	%bulaShort2dwd = (
	bw => "DWSG",
	by => "DWMG",
	be => "DWPG",
	bb => "DWPG",
	hb => "DWHG",
	hh => "DWHH",
	he => "DWOH",
	mv => "DWPH",
	ni => "DWHG",
	nw => "DWEH",
	rp => "DWOI",
	sl => "DWOI",
	sn => "DWLG",
	st => "DWLH",
	sh => "DWHH",
	th => "DWLI",
	xde => "xde",
	xbo => "xbo" );

#
# Dienststellen den entsprechenden Serververzeichnissen zuordnen
#
	%dwd2Dir = (
	DWSG => "SU", # Stuttgart
	DWMG => "MS", # München
	DWPG => "PD", # Potsdam
	DWHG => "HA", # Hamburg
	DWHH => "HA", # Hamburg
	DWOH => "OF", # Offenbach
	DWPH => "PD", # Potsdam
	DWHG => "HA", # Hamburg
	DWEH => "EM", # Essen
	DWOI => "OF", # Offenbach
	DWLG => "LZ", # Leipzig
	DWLH => "LZ", # Leipzig
	DWLI => "LZ", # Leipzig
	DWHC => "HA", # Hamburg
	DWHB => "HA", # Hamburg
	DWPD => "PD", # Potsdam
	DWRW => "PD", # Potsdam
	DWEM => "EM", # Essen
	LSAX => "LZ", # Leipzig
	LSNX => "LZ", # Leipzig
	THLX => "LZ", # Leipzig
	DWOF => "OF", # Offenbach
	DWTR => "OF", # Offenbach
	DWSU => "SU", # Stuttgart
	DWMS => "MS", # München
	xde  => "D",
	xbo  => "Bodensee");
#	???? => "FG" # Freiburg);

	%dwd2Name = (
	EM => "Essen",
	FG => "Freiburg",
	HA => "Hamburg",
	LZ => "Leipzig",
	MS => "München",
	OF => "Offenbach",
	PD => "Potsdam",
	SU => "Stuttgart");

  
# German weekdays  
    @weekdays = ("So", "Mo", "Di", "Mi", "Do", "Fr", "Sa");  
 
    return;
}

sub initDropdownLists($){
	my($hash) = @_;
	my $name = $hash->{NAME};

    # fill $aList
    if (-e $tempDir.$name."_alerts.dir/$name"."_alerts.zip"){
       unzipCapFile($hash);
       buildCAPList($hash);
 	}

    # fill $sList
    getListStations($hash) if(-e $tempDir.$name."_conditions");

	# fill $fList
    getListForecastStations($hash) if(-e $tempDir.$name."_forecasts");

	return;
}

sub gdsHeadlines($;$) {
  my ($d,$sep) = @_;
  my $text = "";
  $sep = (defined($sep)) ? $sep : '|';
  my $count = ReadingsVal($d,'a_count',0);
  for (my $i = 0; $i < $count; $i++) {
    $text .= $sep if $i;
    $text .= ReadingsVal('gds','a_'.$i.'_headline','')
  }
  return $text;
}

sub _readDir($) {
   my ($destinationDirectory) = @_;
   eval { opendir(DIR,$destinationDirectory) or warn "$!"; };
   if ($@) {
      Log3(undef,1,'GDS: file system error '.$@);
      return ("");
   }
   my @files = readdir(DIR); 
   close(DIR); 
   return @files;
}

sub unzipCapFile($) {
	my($hash) = @_;
	my $name = $hash->{NAME};

   my $destinationDirectory = $tempDir.$name."_alerts.dir";
   my $zipname = "$destinationDirectory/$name"."_alerts.zip";
  
   if (-d $destinationDirectory) {
      # delete old files in directory
      my @remove = _readDir($destinationDirectory); 
      foreach my $f (@remove){
         next if -d $f;
         next if $zipname =~ m/$f$/;
   	     Log3($name, 4, "GDS $name: deleting $destinationDirectory/$f"); 
         unlink("$destinationDirectory/$f"); 
      }
   }

   # unzip
   system("/usr/bin/unzip $zipname -d $destinationDirectory");

   # delete archive file
   unlink $zipname unless AttrVal($name,"gdsDebug",0);
   
}

sub mergeCapFile($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    my $destinationDirectory = $tempDir.$name."_alerts.dir";
    my @capFiles = _readDir($destinationDirectory);

    my @alertsArray;
    my $xmlHeader   = '<?xml version="1.0" encoding="UTF-8" standalone="no"?>';
    push (@alertsArray,$xmlHeader);
    push (@alertsArray,"<alert>");
    my $countInfo   = 0;
	
    foreach my $cF (@capFiles){
       # merge all capFiles
       $cF = $destinationDirectory."/".$cF;
       next if -d $cF;
       next unless -s $cF;
       next unless $cF =~ m/\.xml$/; # read xml files only!
       Log3($name, 4, "GDS $name: analyzing $cF"); 

       my ($err,@a) = FileRead({FileName=>$cF,ForceType=>"file" });
       foreach my $l (@a) {
          next unless length($l);
          next if($l =~ m/^\<\?xml version.*/);
          next if($l =~ m/^\<alert.*/);
          next if($l =~ m/^\<\/alert.*/);
          next if($l =~ m/^\<sender\>.*/);
          $countInfo++ if($l =~ m/^\<info\>/);
          push (@alertsArray,$l);
       }
    }
    push (@alertsArray,"</alert>");

    # write the big XML file if needed
    if(AttrVal($name,"gdsDebug", 0)) {
       my $cF = $destinationDirectory."/gds_alerts";
       unlink $cF if -e $cF;
       FileWrite({ FileName=>$cF,ForceType=>"file" },@alertsArray);
    }

    my $xmlContent = join('',@alertsArray);
    return ($countInfo,$xmlContent);
}

# forecast retrieval 
=pod
###################################################################################################
#
#  forecast retrieval 
#
#  provided by jensb
#  modified by betateilchen
#  - use FileRead instead of own I/O
#  - do not set empty readings
#  - allow temperature readings below zero degree
#  - read forecasts on startup if attr gdsSetForecasts already defined before
#  - delete all fc_.* readings in case of new station selection
#
###################################################################################################
=cut

sub retrieveForecasts($$@) {
	#
	# parameter: hash, prefix, region/station, forecast index (0 .. 10)
	#
	my ($hash, $prefix, @a) = @_;
	my $name		= $hash->{NAME};
	my $user		= $hash->{helper}{USER};
	my $pass		= $hash->{helper}{PASS};

	# extract region and station name
	if (!defined($a[2])) {
  		return;
	}
	my $i = index($a[2], '/');
	if ($i <= 0 ) {
		return;
	}

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();  
	my ($dataFile, $found, $line, %fread, $k, $v); 
	my $area      =  utf8ToLatin1(substr($a[2], 0, $i));
	my $station   =  utf8ToLatin1(substr($a[2], $i+1));
	   $station   =~ s/_/ /g; # replace underscore in station name by space
	my $searchLen =  length($station);  
	   %fread     = ();

	# define fetch scope (all forecasts or single forecast)
	my $fc = 0;
	my $fcStep = 1;
	if (defined($a[3]) && $a[3] > 0) {
	    # single forecast
	    $fc = $a[3] - 1;
	    $fcStep = 10;
	}

	# fetch up to 10 forecasts for today and the next 3 days
	do {
		my $day;
		my $early;
		if ($fc < 4) {
			$day = 0;
			$early = 0;
		} else {
			$day = int(($fc - 2)/2);
			$early = $fc%2 == 0;
		} 
		my $areaAndTime = $area;
		if ($day == 1) {
			$areaAndTime .= "_morgen";
		} elsif ($day == 2) {
			$areaAndTime .= "_uebermorgen";
		} elsif ($day == 3) {
			$areaAndTime .= "_Tag4";
		}
		my $timeLabel = undef;
		my $tempLabel = '_tAvgAir';
		my $copyDay = undef;
		my $copyTimeLabel = undef;
		if ($day == 0) {
			if ($fc == 0) {
				$areaAndTime .= "_frueh";  # .. 6 h
				$timeLabel = '06';
				$tempLabel ='_tMinAir';
				$copyDay = 1;
				$copyTimeLabel = '12';
			} elsif ($fc == 1) {
				$areaAndTime .= "_mittag"; # .. 12 h
				$timeLabel = '12';
				$tempLabel .= $timeLabel;
			} elsif ($fc == 2) {
				$areaAndTime .= "_spaet";  # .. 18 h
				$timeLabel = '18';
				$tempLabel ='_tMaxAir';
				$copyDay = 1;
				$copyTimeLabel = '24';
			} elsif ($fc == 3) {
				$areaAndTime .= "_nacht";  # .. 24 h
				$timeLabel = '24';
				$tempLabel .= $timeLabel;
			}
		} else {
			if ($early) {    
				$areaAndTime .= "_frueh";  # .. 12 h
				$timeLabel = '12';
				$tempLabel ='_tMinAir';
				if ($day < 3) {
					$copyDay = $day + 1;
					$copyTimeLabel = '12';
				}
			} else {
				$areaAndTime .= "_spaet";  # .. 24 h
				$timeLabel .= '24';
				$tempLabel ='_tMaxAir';
				if ($day < 3) {
					$copyDay = $day + 1;
					$copyTimeLabel = '24';
				}
			}
		} # if ($day == 0) {

		# define forecast date (based on "now" + day)   
		my $fcEpoch = time() + $day*86400;
		if ($fc == 3) {
			# night continues at next day
			$fcEpoch += 86400;
		}
		my ($fcSec,$fcMin,$fcHour,$fcMday,$fcMon,$fcYear,$fcWday,$fcYday,$fcIsdst) = localtime($fcEpoch);
		my $fcWeekday = $weekdays[$fcWday];
		my $fcDate = sprintf("%02d.%02d.%04d", $fcMday, 1+$fcMon, 1900+$fcYear);
		my $fcDateFound = 0;

		# FTP retrieve
		my $noDataFound = 1;
		Log3($name, 4, "GDS $name: Retrieving forecasts data for day $day: $areaAndTime");
		retrieveFile($hash, "forecasts", $areaAndTime, undef); sleep 1;

		my $fileName = $tempDir.$name."_forecasts";
		my ($err,@data) = FileRead({FileName=>$fileName,ForceType=>"file" });
		return "GDS error reading $fileName" if($err);

		unless ($err) {

			foreach my $l (@data) {
				if (index($l, $fcDate) > 0) { 
					# forecast date found
					$fcDateFound = 1; 
				} # if
				if (index(substr(lc($l),0,$searchLen), substr(lc($station),0,$searchLen)) != -1) { 
					# station found
					$line = $l;
					last; 
				} # if
			} # foreach

			# parse file
			if ($fcDateFound && length($line) > 0) {
				if (index(substr(lc($line),0,$searchLen), substr(lc($station),0,$searchLen)) != -1) {
					# station found but there is no header line and column width varies:
					$line =~ s/---/   ---/g;	# column distance may drop to zero between station name 
												# and invalid temp "---" -> prepend 3 spaces
					$line =~ s/   /;/g;			# now min. column distance is 3 spaces -> convert to semicolon 
					$line =~ s/;+/;/g;			# replace multiple consecutive semicolons by one semicolon
					my @b = split(';', $line);	# split columns by semicolon
					$b[0] =~ s/^\s+|\s+$//g;	# trim station name
					$b[1] =~ s/^\s+|\s+$//g;	# trim temperature
					$b[2] =~ s/^\s+|\s+$//g;	# trim weather   
					if (scalar(@b) > 3) {
						$b[3] =~ s/^\s+|\s+$//g; # trim wind gust
					} else {
						$b[3] = ' ';
					}
					$fread{$prefix."_stationName"} = $area.'/'.$b[0];
					$fread{$prefix.$day.$tempLabel}  = $b[1];
					$fread{$prefix.$day."_weather".$timeLabel} = $b[2];
					$fread{$prefix.$day."_windGust".$timeLabel} = $b[3];
					if ($fc != 3) {
						$fread{$prefix.$day."_weekday"} = $fcWeekday;
					}
					$noDataFound = 0;
				} else {
					# station not found, abort
					$fread{$prefix."_stationName"} = "unknown: $station in $area";
					last;
				}
			}
		} # unless

		if ($noDataFound) {
			# forecast period already passed or no data available 
			$fread{$prefix.$day.$tempLabel} = "---";
			$fread{$prefix.$day."_weather".$timeLabel} = "---";      
			$fread{$prefix.$day."_windGust".$timeLabel} = "---";      
			if ($fc != 3) {
				$fread{$prefix.$day."_weekday"} = $fcWeekday;
			}
		}

		# day change preset by rotation
		my $ltime = ReadingsTimestamp($name, $prefix.$day."_weather".$timeLabel, undef);
		my ($lsec,$lmin,$lhour,$lmday,$lmon,$lyear,$lwday,$lyday,$lisdst);
		if (defined($ltime)) {
			($lsec,$lmin,$lhour,$lmday,$lmon,$lyear,$lwday,$lyday,$lisdst) = localtime(time_str2num($ltime));
		}
		if (!defined($ltime) || $mday != $lmday) {
			# day has changed, rotate old forecast forward by one day because new forecast is not immediately available
			my $temp = $fread{$prefix.$day.$tempLabel};
			if (defined($temp) && substr($temp, 0, 2) eq '--') {
				if (defined($copyTimeLabel)) {
					$fread{$prefix.$day.$tempLabel} = utf8ToLatin1(ReadingsVal($name, $prefix.$copyDay.$tempLabel, '---'));
				} else {
					# today noon/night and 3rd day is undefined
					$fread{$prefix.$day.$tempLabel} = ' ';
				}
			}
			my $weather = $fread{$prefix.$day."_weather".$timeLabel};
			if (defined($weather) && substr($weather, 0, 2) eq '--') {
				if (defined($copyTimeLabel)) {
					$fread{$prefix.$day."_weather".$timeLabel} = 
						utf8ToLatin1(ReadingsVal($name, $prefix.$copyDay."_weather".$copyTimeLabel, '---'));
			} else {
				# today noon/night and 3rd day is undefined
				$fread{$prefix.$day."_weather".$timeLabel} = ' ';
			}
		}
		my $windGust = $fread{$prefix.$day."_windGust".$timeLabel};
		if (defined($windGust) && substr($windGust, 0, 2) eq '--') {
			if (defined($copyTimeLabel)) {
				$fread{$prefix.$day."_windGust".$timeLabel} = 
					utf8ToLatin1(ReadingsVal($name, $prefix.$copyDay."_windGust".$copyTimeLabel, '---'));
			} else {
				# today noon/night and 3rd day is undefined
				$fread{$prefix.$day."_windGust".$timeLabel} = ' ';
			}
		}
	}
	$fc += $fcStep;
	} while ($fc < 10);

	readingsBeginUpdate($hash);
	while (($k, $v) = each %fread) {
		# skip update if no valid data is available
        unless(defined($v))      {delete($defs{$name}{READINGS}{$k}); next;}
		if($v =~ m/^--/)        {delete($defs{$name}{READINGS}{$k}); next;};
        unless(length(trim($v))) {delete($defs{$name}{READINGS}{$k}); next;};
		readingsBulkUpdate($hash, $k, latin1ToUtf8($v)); 
	}
	readingsEndUpdate($hash, 1);
}

sub getListForecastStations($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my @a;
  my @regions = keys(%rmapList);
  foreach (@regions) {
    my $areaAndTime = $_.'_morgen_spaet';
    retrieveFile($hash, "forecasts", $areaAndTime, undef);
    my $fileName = $tempDir.$name."_forecasts";
    my ($err,@data) = FileRead({FileName=>$fileName,ForceType=>"file" });
    return "GDS error reading $fileName" if($err);
    my $lineCount = 0;
    foreach my $line (@data) {
      # skip header lines
      $lineCount++;
      if ($lineCount > 2) {
        if (length($line) == 0 || substr($line, 0, 3) eq '   ') {
          # empty line, done
          last;
        } else {
          # line with station name found
          $line = latin1ToUtf8($line);
          $line =~ s/---/   ---/g;   # column distance may drop to zero between station name and invalid temp "---" -> prepend 3 spaces
          $line =~ s/   /;/g;        # now min. column distance is 3 spaces -> convert to semicolon 
          $line =~ s/;+/;/g;         # replace multiple consecutive semicolons by one semicolon
          my @b = split(';', $line); # split columns by semicolon
          push @a, $_.'/'.$b[0];     # concat region name and station name (1st column)
        }
      }
    } # foreach @data
  } # foreach @regions
   
  if (!@a) {
    Log3($name, 4, "GDS $name: error: unable to read forecast data");
  }
  @a = sort(@a);
  
  $fList = join(",", @a);
  $fList =~ s/\s+,/,/g; # replace multiple spaces followed by comma with comma
  $fList =~ s/\s/_/g;   # replace spaces in stationName with underscore for list in frontend
  
  return;
}

1;

# development documentation
=pod
###################################################################################################
#
#   ToDo
#
#   - improve nonblocking processing
#
###################################################################################################
#
#	Changelog $Revision: $ 
#
###################################################################################################
#
#   ----------  public    RC2 published, SVN #9429
#
#   2015-10-11  renamed   99_gdsUtils.pm to GDSweblink.pm
#               changed   load GDSweblink.pm in eval() on module startup
#
#   2015-10-10  added     attribute gdsHideFile to hide "GDS File" Menu
#               added     optional parameter "host" in define() to override default hostname
#
#               changed   weblink generator           moved into 99_gdsUtils.pm
#               changed   perl module List::MoreUtils is no longer used
#               changed   perl module Text::CSV is no longer needed
#               changed   use binary mode for all ftp transfers to preven errors in images
#
#               fixed     handling for alert items msgType, sent, status
#               fixed     handling for alert messages without "expires" data
#
#               updated   commandref documentation
#
#   ----------  public    RC1 published, SVN #9416
#
#   2015-10-09  removed   createIndexFile()
#               added     forecast retrieval
#               added     weblink generator
#               added     more "set clear ..." commands
#               changed   lots and lots of code cleanup
#               feature   make retrieveFile() nonblocking
#
#
#   2015-10-08  changed   added mergeCapFile()
#                         code cleanup in buildCAPList()
#                         use system call "unzip" instead of Archive::Zip
#               added     NotifyFn for rereadcfg after INITIALIZED
#               improved  startup data retrieval
#               improved  attribute handling
#
#   ----------  public    first publication in ./contrib/55_GDS.2015 for testing
#
#   2015-10-07  changed   remove LWP - we will only use ftp for transfers
#               added     first solution for filemerge
#               added     reliable counter for XML analyzes instead of while(1) loops 
#               added     (implementation started) forecast retrieval by jensb
#               changed   make text file retrieval more generic
#
#   2015-10-06  removed   Coro Support
#               removed   $useFTP - always use http internally 
#               changed   use LWP::Parallel::UserAgent for nonblocking transfers
#               changed   use  Archive::ZIP for alert files transfer and unzip
#
#   2015-10-05  started   redesign for new data structures provided by DWD
#
#   ----------
#
#   2015-09-24  fixed   prevent fhem crash on empty conditions file
#
#   2015-04-07  fixed   a_X_valid calculation: use onset, too
#
#   2015-01-30  changed use own FWEXT instead of HTTPSRV
#
#	2015-01-03	added	multiple alerts handling
#
#	2014-10-15	added	attr disable
#
#	2014-05-23	added	set <name> clear alerts|all
#						fixed some typos in docu and help
#
#	2014-05-22	added	reading a_sent_local
#
#	2014-05-07	added	readings a_onset_local & a_expires_local
#
#	2014-02-26	added	attribute gdsPassiveFtp
#
#	2014-02-04	added	ShutdownFn
#				changed	FTP Timeout
#
#	2013-11-03	added	error handling for malformed XML files from GDS
#
#	2013-08-13	fixed	some minor bugs to prevent annoying console messages
#				added	support for fhem installtions running on windows-based systems
#
#	2013-08-11	added	retrieval for condition maps
#				added	retrieval for forecast maps
#				added	retrieval for warning maps
#				added	retrieval for radar maps
#				modi	use LWP::ua for some file transfers instead of ftp
#						due to transfer errors on image files
#						use parameter #5 = 1 in RetrieveFile for ftp
#				added	get <name> caplist
#
#	2013-08-10	added	some more tolerance on text inputs
#				modi	switched from GetLogList to Log3
#
#	2013-08-09	added	more logging
#				fixed	missing error message if WARNCELLID does not exist
#				update	commandref
#
#	2013-08-08	added	logging
#				added	firewall/proxy support
#				fixed	XMLin missing parameter 
#				added	:noArg to setlist-definitions
#				added	AttrFn
#				modi	retrieval of VHDL messages 30-33
#
#	2013-08-07	public  initial release
#
###################################################################################################
#
# Further informations
#
# DWD's data format is unpleasant to read, 
# since the data columns change depending on the available data
# (e.g. the SSS column for snow disappears when there is no snow).
# It's also in ISO8859-1, i.e. it contains non-ASCII characters. To
# avoid problems, we need some conversion subs in this program.
#
# Höhe  : m über NN
# Luftd.: reduzierter Luftdruck auf Meereshöhe in hPa
# TT    : Lufttemperatur in Grad Celsius
# Tn12  : Minimum der Lufttemperatur, 18 UTC Vortag bis 06 UTC heute, Grad Celsius
# Tx12  : Maximum der Lufttemperatur, 18 UTC Vortag bis 06 UTC heute, Grad Celsius
# Tg24  : Temperaturminimum 5cm ¸ber Erdboden, 22.05.2014 00 UTC bis 24 UTC, Grad Celsius
# Tn24  : Minimum der Lufttemperatur, 22.05.2014 00 UTC bis 24 UTC, Grad Celsius
# Tm24  : Mittel der Lufttemperatur, 22.05.2014 00 UTC bis 24 UTC, Grad Celsius
# Tx24  : Maximum der Lufttemperatur, 22.05.2014 00 UTC bis 24 UTC, Grad Celsius
# Tmin  : Minimum der Lufttemperatur, 06 UTC Vortag bis 06 UTC heute, Grad Celsius
# Tmax  : Maximum der Lufttemperatur, 06 UTC Vortag bis 06 UTC heute, Grad Celsius
# RR1   : Niederschlagsmenge, einstündig, mm = l/qm
# RR12  : Niederschlagsmenge, 12st¸ndig, 18 UTC Vortag bis 06 UTC heute, mm = l/qm
# RR24  : Niederschlagsmenge, 24stündig, 06 UTC Vortag bis 06 UTC heute, mm = l/qm
# SSS   : Gesamtschneehöhe in cm
# SSS24 : Sonnenscheindauer 22.05.2014 in Stunden
# SGLB24: Tagessumme Globalstrahlung am 22.05.2014 in J/qcm 
# DD    : Windrichtung 
# FF    : Windgeschwindigkeit letztes 10-Minutenmittel in km/h
# FX    : höchste Windspitze im Bezugszeitraum in km/h
# ---   : Wert nicht vorhanden
#
###################################################################################################
=cut

# commandref documentation
=pod
=begin html

<a name="GDS"></a>
<h3>GDS</h3>
<ul>

	<b>Prerequesits</b>
	<ul>
	
		<br/>
		Module uses following additional Perl modules:<br/><br/>
		<code>Net::FTP, XML::Simple</code><br/><br/>
		If not already installed in your environment, 
		please install them using appropriate commands from your environment.

	</ul>
	<br/><br/>
	
	<a name="GDSdefine"></a>
	<b>Define</b>
	<ul>

		<br>
		<code>define &lt;name&gt; GDS &lt;username&gt; &lt;password&gt; [&lt;host&gt;]</code><br>
		<br>
		This module provides connection to <a href="http://www.dwd.de/grundversorgung">GDS service</a> 
		generated by <a href="http://www.dwd.de">DWD</a><br>
		<br/>
		Optional paramater host is used to overwrite default host "ftp-outgoing2.dwd.de".<br/>
		<br>
	</ul>
	<br/><br/>

	<a name="GDSset"></a>
	<b>Set-Commands</b><br/>
	<ul>

		<br/>
		<code>set &lt;name&gt; clear alerts|conditions|forecasts|all</code>
		<br/><br/>
		<ul>
			<li>alerts: Delete all a_* readings</li>
			<li>all: Delete all a_*, c_*, g_* and fc_* readings</li>
		</ul>
		<br/>

		<code>set &lt;name&gt; conditions &lt;stationName&gt;</code>
		<br/><br/>
		<ul>Retrieve current conditions at selected station. Data will be updated periodically.</ul>
		<br/>

		<code>set &lt;name&gt; forecasts &lt;region&gt;/&lt;stationName&gt;</code>
		<br/><br/>
		<ul>Retrieve forecasts for today and the following 3 days for selected station.<br/>
		    Data will be updated periodically.</ul>
		<br/>

		<code>set &lt;name&gt; help</code>
		<br/><br/>
		<ul>Show a help text with available commands</ul>
		<br/>

		<code>set &lt;name&gt; update</code>
		<br/><br/>
		<ul>Update conditions and forecasts readings at selected station and restart update-timer</ul>
		<br/>

		<li>condition readings generated by SET use prefix "c_"</li>
		<li>forecast readings generated by SET use prefix "fcd_" and a postfix of "hh"<br/> 
		   with d=relative day (0=today) and hh=last hour of forecast (exclusive)</li>
		<li>readings generated by SET will be updated automatically every 20 minutes</li>

	</ul>
	<br/><br/>

	<a name="GDSget"></a>
	<b>Get-Commands</b><br/>
	<ul>

		<br/>
		<code>get &lt;name&gt; alerts &lt;region&gt;</code>
		<br/><br/>
		<ul>Retrieve alert message for selected region from previously read alert file (see rereadcfg)</ul>
		<br/>

		<code>get &lt;name&gt; conditions &lt;stationName&gt;</code>
		<br/><br/>
		<ul>Retrieve current conditions at selected station</ul>
		<br/>

		<code>get &lt;name&gt; forecasts &lt;region&gt;</code>
		<br/><br/>
		<ul>Retrieve forecasts for today and the following 3 days for selected region as text</ul>
		<br/>

		<code>get &lt;name&gt; conditionsmap &lt;region&gt;</code>
		<br/><br/>
		<ul>Retrieve map (imagefile) showing current conditions at selected station</ul>
		<br/>

		<code>get &lt;name&gt; forecastsmap &lt;stationName&gt;</code>
		<br/><br/>
		<ul>Retrieve map (imagefile) showing forecasts for selected region</ul>
		<br/>

		<code>get &lt;name&gt; headlines</code>
		<br/><br/>
		<ul>Returns a string, containing all alert headlines separated by |</ul>
		<br/>

		<code>get &lt;name&gt; help</code>
		<br/><br/>
		<ul>Show a help text with available commands</ul>
		<br/>

		<code>get &lt;name&gt; list capstations|data|stations</code>
		<br/><br/>
		<ul>
			<li><b>capstations:</b> Retrieve list showing all defined warning regions. 
			    You can find your WARNCELLID with this list.</li>
			<li><b>data:</b> List current conditions for all available stations in one single table</li>
			<li><b>stations:</b> List all available stations that provide conditions data</li>
		</ul>
		<br/>

		<code>get &lt;name&gt; radarmap &lt;region&gt;</code>
		<br/><br/>
		<ul>Retrieve map (imagefile) containig radar view from selected region</ul>
		<br/>

		<code>get &lt;name&gt; rereadcfg</code>
		<br/><br/>
		<ul>Reread all required data from DWD Server manually: station list and CAP data</ul>
		<br/>

		<code>get &lt;name&gt; warnings &lt;region&gt;</code>
		<br/><br/>
		<ul>Retrieve current warnings report for selected region
			<ul>
				<br/>
				<li>report type VHDL30 = regular report, issued daily</li>
				<li>report type VHDL31 = regular report, issued before weekend or national holiday</li>
				<li>report type VHDL32 = preliminary report, issued on special conditions</li>
				<li>report type VHDL33 = cancel report, issued if necessary to cancel VHDL32</li>
			</ul>
		</ul>
		<br/>

		<code>get &lt;name&gt; warningssmap &lt;region&gt;</code>
		<br/><br/>
		<ul>Retrieve map (imagefile) containig current warnings for selected region marked with symbols</ul>
		<br/><br/>
		<b>All downloaded mapfiles</b> can be found inside "GDS Files" area in left navigation bar.

	</ul>
	<br/><br/>

	<a name="GDSattr"></a>
	<b>Attributes</b><br/><br/>
	<ul>
		<li><a href="#do_not_notify">do_not_notify</a></li>
		<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
		<br/>
		<li><b>disable</b> - if set, gds will not try to connect to internet</li>
		<li><b>gdsAll</b> - defines filter for "all data" from alert message</li>
		<li><b>gdsDebug</b> - defines filter for debug informations</li>
		<li><b>gdsSetCond</b> - defines conditions area to be used after system restart</li>
		<li><b>gdsSetForecast</b> - defines forecasts region/station to be used after system restart</li>
		<li><b>gdsLong</b> - show long text fields "description" and "instruction" from alert message in readings</li>
		<li><b>gdsPolygon</b> - show polygon data from alert message in a reading</li>
		<li><b>gdsHideFiles</b> - if set to 1, the "GDS Files" menu in the left navigation bar will not be shown</li>
		<br/>
		<li><b>gdsPassiveFtp</b> - set to 1 to use passive FTP transfer</li>
		<li><b>gdsFwName</b> - define firewall hostname in format &lt;hostname&gt;:&lt;port&gt;</li>
		<li><b>gdsFwType</b> - define firewall type in a value 0..7 please refer to
		    <a href="http://search.cpan.org/~gbarr/libnet-1.22/Net/Config.pm#NetConfig_VALUES">cpan documentation</a> 
		    for further informations regarding firewall settings.</li>
	</ul>
	<br/><br/>

	<b>Generated Readings/Events:</b>
	<br/><br/>
	<ul>
		<li><b>_&lt;readingName&gt;</b> - debug informations</li>
		<li><b>a_X_&lt;readingName&gt;</b> - weather data from CAP alert messages. Readings will NOT be updated automatically<br/>
			a_ readings contain a set of alert inforamtions, X represents a numeric set identifier starting with 0<br/>
			that will be increased for every valid alert message in selected area<br/></li>
		<li><b>a_count</b> - number of currently valid alert messages, can be used for own loop iterations on alert messages</li>
		<li><b>a_valid</b> - returns 1 if at least one of decoded alert messages is valid</li>
		<li><b>c_&lt;readingName&gt;</b> - weather data from SET weather conditions. 
		    Readings will be updated every 20 minutes.</li>
		<li><b>fc?_&lt;readingName&gt;??</b> - weather data from SET weather forecasts, 
		    prefix by relative day and postfixed by last hour. Readings will be updated every 20 minutes.<br>
			<i><ul>
				<li>0_weather06 and ?_weather12 (with ? greater 0) is the weather in the morning</li>
				<li>0_weather12 is the weather at noon</li>
				<li>0_weather18 and ?_weather24 (with ? greater 0) is the weather in the afternoon</li>
				<li>0_weather24 is the weather at midnight</li>
				<li>0_windGust06 and ?_windGust12 (with ? greater 0) is the wind in the morning</li>
				<li>0_windGust12 is the wind at noon</li>
				<li>0_windGust18 and ?_windGust24 (with ? greater 0) is the wind in the afternoon</li>
				<li>0_windGust24 is the wind at midnight</li>
				<li>?_tMinAir is minimum temperature in the morning</li>
				<li>0_tAvgAir12 is the average temperature at noon</li>
				<li>?_tMaxAir is the maximum temperature in the afternoon</li>
				<li>0_tAvgAir24 is the average temperature at midnight</li>        
			</ul></i>
		</li>
		<li><b>g_&lt;readingName&gt;</b> - weather data from GET weather conditions. 
		    Readings will NOT be updated automatically</li>
	</ul>
	<br/><br/>

	<b>Author's notes</b><br/><br/>
	<ul>

		<li>Module uses following additional Perl modules:<br/><br/>
		<code>Net::FTP, XML::Simple</code><br/><br/>
		If not already installed in your environment, please install them using appropriate commands from your environment.</li>
		<br/><br/>
		<li>Have fun!</li><br/>

	</ul>

</ul>

=end html
=begin html_DE

<a name="GDS"></a>
<h3>GDS</h3>
<ul>
Sorry, keine deutsche Dokumentation vorhanden.<br/><br/>
Die englische Doku gibt es hier: <a href='http://fhem.de/commandref.html#GDS'>GDS</a><br/>
</ul>
=end html_DE
=cut
