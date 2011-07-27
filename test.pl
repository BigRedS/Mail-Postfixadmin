#! /usr/bin/perl

use Vpostmail;
use 5.010;

my $v = Vpostmail->new();

print "Number of users on the system: ";
say $v->numUsers();

print "Number of domains on this system: ";
say $v->numDomains();

say "List of domains on this system: ";
my @domains = $v->listDomains();
foreach(@domains){
	print "\t$_\n";
}

say "list of all users on the system ";
my @users = $v->listUsers();
foreach(@users){
	print "\t$_\n";
}

print "Check avi.co exists: ";
say $v->domainExists("avi.co");

print "Set domain to avi.co.\n";
$v->setDomain('avi.co');

print "Number of users on domain set with \$v->setDomain: ";
say $v->numUsers;

print "Users on domain:\n";
my @users = $v->listUsers();
foreach(@users){
	print "\t$_\n";
}

print "Check whether user $ARGV[0] exists:";
say $v->userExists($ARGV[0]);

print "User info for $ARGV[0]";
my %userinfo = $v->getUserInfo($ARGV[0]);
foreach(keys(%userinfo)){
	print"$_=>$userinfo{$_}\n";
}


print "Unset domain from avi.co.\n";
$v->unsetDomain();
say $v->getDomain();

print "\n";
