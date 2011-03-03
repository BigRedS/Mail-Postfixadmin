#! /usr/bin/perl
use warnings;
use strict;
use 5.010;

my %configFiles = (
	'postfix' => "/etc/postfix/main.cf",
	'dovecot' => "/etc/dovecot/dovecot-sql.conf"
);
my $postfixConfig

sub vdominfo() {
	my $domain = shift;
	my $db = &db;

}


# postfixConfig
# Parses the postfix config file ($configFiles{'postfix'})
# and populates %postfixConfig with useful things
sub postfixConfig (){
	open($fh, "<", $configFiles{'postfix'}) or die "Error opening Postfix config file $configFiles{'postfix'}";
	while(<$fh>){
		my ($k,$v) = split(/\s*=\s*/, $_);

	
}


# dbConnection
# Deduces db details and establishes a connection to the db. 
# Returns a DBI/DBD object
sub dbConnection(){
	## Need to deduce credentials more intelligently
	open($fh, "<", $configFiles{'postfix'};
	my $somefile;
	while(<$fh>){
		if(/mysql:/){
			$somefile = (split(/mysql:/, $_))[1];
			last;
		}
	}
	close($fh);
	open($fh, "<", $somefile);
	my %db;
	while(<$fh>){
		$_ =~ s/(#.+)//
		my ($k,$v) = split(/\s*=\s*/, $_);
		given($k){
			when(/user/){%db{user}=$v;}
			when(/password/){%db{pass}=$v;}
			when(/host/){%db{host}=$v;}
			when(/dbname/){%db{name}=$v;}
		}
	}

	my $dbh = DBI->connect("DBI:mysql:$db{'name'}:host=$db{'host'}", $db{'user'}, $db{'pass'}) || die "Could not connect to database: $DBI::errstr";
	return $dbh
}
