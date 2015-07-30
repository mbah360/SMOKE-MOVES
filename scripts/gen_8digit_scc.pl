#!/usr/bin/perl
#
# Filename   : gen_8digit_scc_v1.2.pl
# Author     : Catherine Seppanen, UNC
# Version    : 1.2
# Description: Generate mapping of 8-digit SCCs to aggregated SCCs.
# Updates    : Version 1.1 - switch to querying database for list of SCCs
#              Version 1.2 - handle dropped SCCs
#
# Usage: gen_8digit_scc_v1.2.pl [-u <mysql user>] [-p <mysql password>]
#                               -r RPD|RPV|RPP|RPH
#                               [--fuel_agg <FuelTypeMappingFile>]
#                               [--src_agg <SourceTypeMappingFile>]
#                               [--road_agg <RoadTypeMappingFile>]
#                               [--proc_agg <ProcessTypeMappingFile>]
#                               <InputDBList>
# where
#   mysql user - MySQL user with read privileges in the MOVES databases
#   mysql password - password for the MySQL user (if needed)
#   RPD|RPP|RPV|RPH - emission factor table to query (rateperdistance, ratepervehicle, rateperprofile, or rateperhour)
#   FuelTypeMappingFile - list of MOVES fuel type IDs and corresponding aggregated fuel type ID
#   SourceTypeMappingFile - list of MOVES source type IDs and corresponding aggregated source type ID
#   RoadTypeMappingFile - list of MOVES road type IDs and corresponding aggregated road type ID
#   ProcessTypeMappingFile - list of MOVES process type IDs and corresponding aggregated process type ID
#   InputDBList - list of MySQL database names to process (generated by runspec_generator.pl MOVES preprocessor); only first database listed will be used

use strict;
use warnings 'FATAL' => 'all';
use DBI;
use Getopt::Long;

my %runInfo = (
  'RPD' => 'rateperdistance',
  'RPV' => 'ratepervehicle',
  'RPP' => 'rateperprofile',
  'RPH' => 'rateperhour'
);

#================================================================================================
# Process command line arguments

my ($sqlUser, $sqlPass, $runType) = '';
my ($fuelAggFile, $srcAggFile, $roadAggFile, $procAggFile) = '';
GetOptions('user|u:s' => \$sqlUser, 
           'pass|p:s' => \$sqlPass, 
           'runtype|r:s' => \$runType, 
           'fuel_agg=s' => \$fuelAggFile, 
           'src_agg=s' => \$srcAggFile, 
           'road_agg=s' => \$roadAggFile, 
           'proc_agg=s' => \$procAggFile);

# check for valid run type
die "Please specify a run type using '-r'.\n" unless $runType;
die "Please specify a valid type after '-r': RPD, RPV, RPP, or RPH.\n" unless $runInfo{$runType};

(scalar(@ARGV) == 1) or die <<END;
Usage: $0 [-u <mysql user>] [-p <mysql password>] -r RPD|RPV|RPP|RPH 
  [--fuel_agg <FuelTypeMappingFile>]
  [--src_agg <SourceTypeMappingFile>]
  [--road_agg <RoadTypeMappingFile>]
  [--proc_agg <ProcessTypeMappingFile>]
  <InputDBList>
END

my ($dbFile) = @ARGV;

#================================================================================================
# Read the input database list file generated from the MOVES Driver Script preprocessor 

my $dbFH;
open($dbFH, "<", $dbFile) or die "Unable to open input file of database names: $dbFile\n";

my $line = <$dbFH>;
chomp($line);
if ($line =~ /^\s*debug\s*$/i)
{
  $line = <$dbFH>;
  chomp($line);
}
my $hostname = $line;

$line = <$dbFH>;  # line is output directory (unused in this script)
chomp($line);

my @dbList;
while ($line = <$dbFH>)
{
  chomp($line);
  next unless $line; # skip blank lines
  push(@dbList, $line);
}

close ($dbFH);

#================================================================================================
# Process SCC aggregation files

my $scc_sql = 'SCC';

if ($fuelAggFile || $srcAggFile || $roadAggFile || $procAggFile)
{
  my @sql_pieces = map { BuildAggregationSQL(@$_) } 
                       (['fuel', $fuelAggFile, 3], 
                        ['source', $srcAggFile, 5], 
                        ['road', $roadAggFile, 7], 
                        ['process', $procAggFile, 9]);
  
  $scc_sql = "CONCAT('22', " . join(', ', @sql_pieces) . ')';
}

#================================================================================================
# Query database for list of SCCs

# make connection to database
my $db = $dbList[0];
my $connectionInfo = "dbi:mysql:$db;$hostname";

my $dbh = DBI->connect($connectionInfo, $sqlUser, $sqlPass) or die "Could not connect to database: $db\n";

my $sth = $dbh->prepare(<<END);
  SELECT $scc_sql AS agg_scc
    FROM $runInfo{$runType}
   WHERE $scc_sql IS NOT NULL
GROUP BY agg_scc
ORDER BY agg_scc
END

$sth->execute() or die 'Error executing query: ' . $sth->errstr;

print '"Full SCC","Abbreviated SCC"' . "\n";
while (my ($scc) = $sth->fetchrow_array())
{
  print $scc . ',' . substr($scc, 0, 8) . "00\n";
}

#================================================================================================
# Subroutines

# Build SQL to map input SCCs to output SCCs
sub BuildAggregationSQL
{
  my ($aggType, $aggFile, $substrPos) = @_;
  
  unless ($aggFile)
  {
    return "SUBSTR(SCC, $substrPos, 2)";
  }
  
  my $aggFH;
  open($aggFH, "<", $aggFile) or die "Unable to open $aggType aggregation file: $aggFile\n";
  
  my $sql = "CASE SUBSTR(SCC, $substrPos, 2) ";
  while (my $line = <$aggFH>)
  {
    chomp($line);
  
    my ($inputID, $outputID) = ($line =~ /^(\d\d?),(\d\d?),/);
    next unless $inputID && $outputID; # skip lines without data
    
    $inputID = '0' . $inputID if length($inputID) == 1;
    $outputID = '0' . $outputID if length($outputID) == 1;
    
    $sql .= "WHEN '$inputID' THEN '$outputID' ";
  }
  
  $sql .= 'ELSE NULL END';
  
  close ($aggFH);
  
  return $sql;
}