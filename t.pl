#! /usr/bin/perl

use strict;
use Vpostmail;
use 5.010;


my $domain = $ARGV[0];

my $v = Vpostmail->new(
);

my %options = $v->getOptions;
foreach(keys(%options)){
	print "$_ => $options{$_}\n" unless $_ eq '';
}

$v->setDomain($domain);

#$v->createDomain;
print "domain exists: <", $v->domainExists, ">\n";
print "[\n$v->{infostr}\n]";
$v->removeDomain;
print "domain exists: <", $v->domainExists, ">\n";

print "\n";
