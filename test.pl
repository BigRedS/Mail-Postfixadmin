#! /usr/bin/perl

use Vpostmail;
use 5.010;

my $d = Vpostmail->new();

print "Number of users on the system: ";
say $d->numUsers();

print "Number of domains on this system: ";
say $d->numDomains();

say "List of domains on this system: ";
my @domains = $d->listDomains();
foreach(@domains){
	print "\t$_\n";
}

say "list of all users on the system ";
my @users = $d->listUsers();
foreach(@users){
	print "\t$_\n";
}


exit 0;

print "Set domain to avi.co.\n";
$d->setDomain('avi.co');

print "Number of users on domain set with \$d->setDomain: ";
say $d->numUsers;

print "Users on domain:\n";
my @users = $d->listUsers();
foreach(@users){
	print "\t$_\n";
}

print "Unset domain from avi.co.\n";
$d->unsetDomain();
say $d->getDomain();

print "\n";
