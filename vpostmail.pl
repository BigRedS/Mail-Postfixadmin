#! /usr/bin/perl
use warnings;
use strict;
use 5.010;
use DBI;
use Data::Dumper;

# # # # # # # # # # # # # # # # # 
# # Configuration!
#
my %configFiles = (
	'postfix' => "/etc/postfix/main.cf",
	'dovecot' => "/etc/dovecot/dovecot-sql.conf"
);
my $postfixConfig;

## This should be done more intelligently. We must be able to parse something
##+to find this sort of info.
my %tables = (
	'admin' 	=> 'admin',
	'alias'		=> 'alias',
	'alias_domain'	=> 'alias_domain',
	'config'	=> 'config',
	'domain'	=> 'domain',
	'domain_admins'	=> 'domain_admins',
	'fetchmail'	=> 'fetchmail',
	'log'		=> 'log',
	'mailbox'	=> 'mailbox',
	'quota'		=> 'quota',
	'quota2'	=> 'quota2',
	'vacation' 	=> 'vacation',
	'vacation_notification' => 'vacation_notification'
);


my %fields;
$fields{'admin'} = {
			'domain' 	=> 'domain',
			'description'	=> 'description'
};
$fields{'domain'} = {
			'domain'	=> 'domain',
			'aliases'	=> 'aliases',
			'mailboxes'	=> 'mailboxes',
			'maxquota'	=> 'maxquota',
			'quota'		=> 'quota',
			'transport'	=> 'transport',
			'backupmx'	=> 'backupmx',
			'created'	=> 'created',
			'modified'	=> 'modified',
			'active'	=> 'active'
};
$fields{'mailbox'} = {
			'mailbox'	=> 'mailbox',
			'username'	=> 'username'
};
$fields{'domain_admins'} = {
			'domain'	=> 'domain',
			'username'	=> 'username'
};

# # # # # # # # # # # # # # # # # 
# # vpopmail cloning:
#
		
foreach my $domain (@ARGV){
	&printVdomInfo( &vdominfo($domain) );
}

	

# # # # # # # # # # # # # # # # # 
# # Subs to do vpopmail clones
#

## Needs some way of coping with there being no admin users in the db
##+there are also 'ALL' admins, so a domain doesn't necessarily need
##+its own.
sub vdominfo() {
	my $domain = shift;
	my $db = &dbConnection;
	my $usersQuery = "select count(*) from $tables{'mailbox'} where `$fields{'mailbox'}{'username'}` like '%$domain'";
	my $usersCount = ($db->selectrow_array($usersQuery))[0];
	my $domainAdminQuery = "select `$fields{'domain_admins'}{'username'}` from `$tables{'domain_admins'}` where `$fields{'domain_admins'}{'domain'}` = '$domain'";
	print $domainAdminQuery."\n\n";
	my $domainAdmin = $db->selectrow_array($domainAdminQuery);

	my $domainInfoQuery = "select $fields{'domain'}{'aliases'}, $fields{'domain'}{'mailboxes'}, $fields{'domain'}{'maxquota'}, $fields{'domain'}{'quota'}, $fields{'domain'}{'transport'}, $fields{'domain'}{'backupmx'}, $fields{'domain'}{'created'}, $fields{'domain'}{'modified'}, $fields{'domain'}{'active'}";
	$domainInfoQuery.= " from $tables{'domain'} where $fields{'domain'}{'domain'} = '$domain'";
	my $domainInfo=$db->selectrow_hashref($domainInfoQuery);
	$$domainInfo{'_usersCount'} =  $usersCount;
	$$domainInfo{'_adminList'} = $domainAdmin;
	return $domainInfo;
}
sub printVdomInfo(){
	## This needs to be sorted properly:
	my %info =%{(shift)};
	my $key;
	foreach $key (keys(%info)){
		my $value = $info{$key};
		print "$key\t";
		if(ref $value eq 'ARRAY'){
			foreach(@$value){
				print $_." ";
			}
			print "\n";
		}else{
			say $value;
		}
	}
}

#sub vuserinfo() {



# # # # # # # # # # # # # # # # # 
# # All the tedium that you don't really want to read
#

# postfixConfig
# Parses the postfix config file ($configFiles{'postfix'})
# and populates %postfixConfig with useful things
sub postfixConfig {
	my $fh;
	open($fh, "<", "/etc/postfix/main.cf") or die "Error opening Postfix config file $configFiles{'postfix'} : $!";
	while(<$fh>){
		my ($k,$v) = split(/\s*=\s*/, $_);
	}
	
}


# dbConnection
# Deduces db details and establishes a connection to the db. 
# Returns a DBI/DBD object
sub dbConnection(){
	## Need to deduce credentials more intelligently
	my $somefile;
	open(my $conf, "<", $configFiles{'postfix'}) or die ("Error opening postfix config file at $configFiles{'postfix'} : $!");
	while(<$conf>){
		if(/mysql:/){
			$somefile = (split(/mysql:/, $_))[1];
			last;
		}
	}
	close($conf);
	$somefile =~ s/\/\//\//g;
	chomp $somefile;
	open(my $fh, "<", $somefile) or die ("Error opening postfixy db conf file ($somefile) : $!");
	my %db;
	while(<$fh>){
		if (/=/){
			my $line = $_;
			$line =~ s/(\s*#.+)//;
			$line =~ s/\s*$//;
			my ($k,$v) = split(/\s*=\s*/, $_);
			chomp $v;
			given($k){
				when(/user/){$db{user}=$v;}
				when(/password/){$db{pass}=$v;}
				when(/host/){$db{host}=$v;}
				when(/dbname/){$db{name}=$v;}
			}
		}
	}

	
#	print Dumper(%db);


	my $dbh = DBI->connect("DBI:mysql:$db{'name'}:host=$db{'host'}", $db{'user'}, $db{'pass'}) || die "Could not connect to database: $DBI::errstr";
	return $dbh
}
