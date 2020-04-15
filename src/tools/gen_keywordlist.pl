#----------------------------------------------------------------------
#
# gen_keywordlist.pl
#	Perl script that transforms a list of keywords into a ScanKeywordList
#	data structure that can be passed to ScanKeywordLookup().
#
# The input is a C header file containing a series of macro calls
#	PG_KEYWORD("keyword", ...)
# Lines not starting with PG_KEYWORD are ignored.  The keywords are
# implicitly numbered 0..N-1 in order of appearance in the header file.
# Currently, the keywords are required to appear in ASCII order.
#
# The output is a C header file that defines a "const ScanKeywordList"
# variable named according to the -v switch ("ScanKeywords" by default).
# The variable is marked "static" unless the -e switch is given.
#
# ScanKeywordList uses hash-based lookup, so this script also selects
# a minimal perfect hash function for the keyword set, and emits a
# static hash function that is referenced in the ScanKeywordList struct.
# The hash function is case-insensitive unless --no-case-fold is specified.
# Note that case folding works correctly only for all-ASCII keywords!
#
#
# Portions Copyright (c) 1996-2019, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
# src/tools/gen_keywordlist.pl
#
#----------------------------------------------------------------------

use strict;
use warnings;
use Getopt::Long;

use FindBin;
use lib $FindBin::RealBin;

use PerfectHash;

my $output_path = '';
my $extern      = 0;
my $case_fold   = 1;
my $varname     = 'ScanKeywords';

GetOptions(
	'output:s'   => \$output_path,
	'extern'     => \$extern,
	'case-fold!' => \$case_fold,
	'varname:s'  => \$varname) || usage();

my $kw_input_file = shift @ARGV || die "No input file.\n";

# Make sure output_path ends in a slash if needed.
if ($output_path ne '' && substr($output_path, -1) ne '/')
{
	$output_path .= '/';
}

$kw_input_file =~ /(\w+)\.h$/
  || die "Input file must be named something.h.\n";
my $base_filename = $1 . '_d';
my $kw_def_file   = $output_path . $base_filename . '.h';

open(my $kif,   '<', $kw_input_file) || die "$kw_input_file: $!\n";
open(my $kwdef, '>', $kw_def_file)   || die "$kw_def_file: $!\n";

# Opening boilerplate for keyword definition header.
printf $kwdef <<EOM, $base_filename, uc $base_filename, uc $base_filename;
/*-------------------------------------------------------------------------
 *
 * %s.h
 *    List of keywords represented as a ScanKeywordList.
 *
 * Portions Copyright (c) 1996-2019, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *  ******************************
 *  *** DO NOT EDIT THIS FILE! ***
 *  ******************************
 *
 *  It has been GENERATED by src/tools/gen_keywordlist.pl
 *
 *-------------------------------------------------------------------------
 */

#ifndef %s_H
#define %s_H

#include "common/kwlookup.h"

EOM

# Parse input file for keyword names.
my @keywords;
while (<$kif>)
{
	if (/^PG_KEYWORD\("(\w+)"/)
	{
		push @keywords, $1;
	}
}

# When being case-insensitive, insist that the input be all-lower-case.
if ($case_fold)
{
	foreach my $kw (@keywords)
	{
		die qq|The keyword "$kw" is not lower-case in $kw_input_file\n|
		  if ($kw ne lc $kw);
	}
}

# Error out if the keyword names are not in ASCII order.
#
# While this isn't really necessary with hash-based lookup, it's still
# helpful because it provides a cheap way to reject duplicate keywords.
# Also, insisting on sorted order ensures that code that scans the keyword
# table linearly will see the keywords in a canonical order.
for my $i (0 .. $#keywords - 1)
{
	die
	  qq|The keyword "$keywords[$i + 1]" is out of order in $kw_input_file\n|
	  if ($keywords[$i] cmp $keywords[ $i + 1 ]) >= 0;
}

# Emit the string containing all the keywords.

printf $kwdef qq|static const char %s_kw_string[] =\n\t"|, $varname;
print $kwdef join qq|\\0"\n\t"|, @keywords;
print $kwdef qq|";\n\n|;

# Emit an array of numerical offsets which will be used to index into the
# keyword string.  Also determine max keyword length.

printf $kwdef "static const uint16 %s_kw_offsets[] = {\n", $varname;

my $offset  = 0;
my $max_len = 0;
foreach my $name (@keywords)
{
	my $this_length = length($name);

	print $kwdef "\t$offset,\n";

	# Calculate the cumulative offset of the next keyword,
	# taking into account the null terminator.
	$offset += $this_length + 1;

	# Update max keyword length.
	$max_len = $this_length if $max_len < $this_length;
}

print $kwdef "};\n\n";

# Emit a macro defining the number of keywords.
# (In some places it's useful to have access to that as a constant.)

printf $kwdef "#define %s_NUM_KEYWORDS %d\n\n", uc $varname, scalar @keywords;

# Emit the definition of the hash function.

my $funcname = $varname . "_hash_func";

my $f = PerfectHash::generate_hash_function(\@keywords, $funcname,
	case_fold => $case_fold);

printf $kwdef qq|static %s\n|, $f;

# Emit the struct that wraps all this lookup info into one variable.

printf $kwdef "static " if !$extern;
printf $kwdef "const ScanKeywordList %s = {\n", $varname;
printf $kwdef qq|\t%s_kw_string,\n|,            $varname;
printf $kwdef qq|\t%s_kw_offsets,\n|,           $varname;
printf $kwdef qq|\t%s,\n|,                      $funcname;
printf $kwdef qq|\t%s_NUM_KEYWORDS,\n|,         uc $varname;
printf $kwdef qq|\t%d\n|,                       $max_len;
printf $kwdef "};\n\n";

printf $kwdef "#endif\t\t\t\t\t\t\t/* %s_H */\n", uc $base_filename;


sub usage
{
	die <<EOM;
Usage: gen_keywordlist.pl [--output/-o <path>] [--varname/-v <varname>] [--extern/-e] [--[no-]case-fold] input_file
    --output        Output directory (default '.')
    --varname       Name for ScanKeywordList variable (default 'ScanKeywords')
    --extern        Allow the ScanKeywordList variable to be globally visible
    --no-case-fold  Keyword matching is to be case-sensitive

gen_keywordlist.pl transforms a list of keywords into a ScanKeywordList.
The output filename is derived from the input file by inserting _d,
for example kwlist_d.h is produced from kwlist.h.
EOM
}
