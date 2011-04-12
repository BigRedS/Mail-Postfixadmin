#! /usr/bin/perl

use strict;
use 5.010;
use DBI;
use Data::Dumper;
package Vpostmail;
sub new() {
	my $class = shift;
	my $self = {};
	bless($self,$class);
#	$self->{_domain};
	$self->{dbi} = &_dbConnection('/etc/postfix/main.cf');
	$self->{configFiles}->{'postfix'} = '/etc/postfix/main.cf';
	my %_tables = &_tables;
	$self->{tables} = \%_tables;
	my %_fields = &_fields;
	$self->{fields} = \%_fields;
	return $self;

	print Data::Dumper::Dumper(%_fields);
}

sub getTables(){
	my $self = shift;
	return $self->{tables}
}

sub getDomain(){
	my $self = shift;
	return $self->{_domain}
}

sub setDomain(){
	my $self = shift;
	my $domain = shift;
	$self->{_domain} = $domain;
	return $self->{_domain};
}

sub unsetDomain(){
	my $self = shift;
	$self->{_domain} = undef;
	return $self->{_domain}
}

sub getUser(){
	my $self = shift;
	return $self->{_user};	
}
sub setUser(){
	my $self = shift;
	my $username = shift;
	if (($self->{_domain}) && ($username !~ /\@/)){
		$username.='@'.$self->{_domain};
	}
	$self->{_user} = $username;
	return $self->{_user};
}

sub numDomains(){
	my $self = shift;
	my $query = "select count(*) from $self->{tables}->{domain}";
	my $numDomains = ($self->{dbi}->selectrow_array($query))[0];
	$numDomains--;	# since there's an 'ALL' domain in the db
	$self->{_numDomains} = $numDomains;
	return $self->{_numDomains};
}

sub numUsers(){
	my $self = shift;
	my $query;
	if ($self->{_domain}){
		 $query = "select count(*) from `$self->{tables}->{alias}` where $self->{fields}->{alias}->{domain} = \'$self->{_domain}\'"
	}else{
		$query = "select count(*) from `$self->{tables}->{alias}`";
	}
	my $numUsers = ($self->{dbi}->selectrow_array($query))[0];
	return $numUsers;
	return $query;
}

sub listDomains(){
	my $self = shift;
	my $query;
	my $query = "select domain from $self->{tables}->{domain}";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my @domains;
	while(my @row = $sth->fetchrow_array()){
		push(@domains, $row[0]) unless $row[0] =~ /^ALL$/;
	}
	return @domains;
}

sub listUsers(){
	my $self = shift;
	my $query;
	if ($self->{_domain}){
		$query = "select $self->{fields}->{alias}->{address} from $self->{tables}->{alias} where $self->{fields}->{alias}->{domain} = \'$self->{_domain}\'";
	}else{
		$query = "select $self->{fields}->{alias}->{address} from $self->{tables}->{alias}";
	}
	my $sth = $self->{dbi}->prepare($query);
	print "[[$query]]";
	$sth->execute;
	my @users;
	while(my @row = $sth->fetchrow_array()){
		push(@users, $row[0]);
	}
	return @users;


}

sub getUserInfo(){
	my $self = shift;
	$self->_user = shift if(!$self->{_user});
	my $user = $self->{_user};
	my %userinfo;
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
 # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# dbConnection
# Deduces db details and establishes a connection to the db. 
# Returns a DBI/DBD object
sub _dbConnection(){
        ## Need to deduce credentials more intelligently
	my $maincf = shift;
        my $somefile;
        open(my $conf, "<", $maincf) or die ("Error opening postfix config file at $maincf : $!");
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
        my $dbh = DBI->connect("DBI:mysql:$db{'name'}:host=$db{'host'}", $db{'user'}, $db{'pass'}) || die "Could not connect to database: $DBI::errstr";
        return $dbh
}

sub _tables(){
	my %tables = ( 
	        'admin'         => 'admin',
	        'alias'         => 'alias',
	        'alias_domain'  => 'alias_domain',
	        'config'        => 'config',
	        'domain'        => 'domain',
	        'domain_admins' => 'domain_admins',
	        'fetchmail'     => 'fetchmail',
	        'log'           => 'log',
	        'mailbox'       => 'mailbox',
	        'quota'         => 'quota',
	        'quota2'        => 'quota2',
	        'vacation'      => 'vacation',
	        'vacation_notification' => 'vacation_notification'
	);
	return %tables;
}

sub _fields(){
	my %fields;
	$fields{'admin'} = { 
	                        'domain'        => 'domain',
	                        'description'   => 'description'
	};
	$fields{'alias'} = {
				'address'	=> 'address'
	};
	$fields{'domain'} = { 
	                        'domain'        => 'domain',
	                        'aliases'       => 'aliases',
	                        'mailboxes'     => 'mailboxes',
	                        'maxquota'      => 'maxquota',
	                        'quota'         => 'quota',
	                        'transport'     => 'transport',
	                        'backupmx'      => 'backupmx',
	                        'created'       => 'created',
	                        'modified'      => 'modified',
	                        'active'        => 'active'
	};
	$fields{'mailbox'} = { 
	                        'mailbox'       => 'mailbox',
	                        'username'      => 'username'
	};
	$fields{'domain_admins'} = {
	                        'domain'        => 'domain',
	                        'username'      => 'username'
	};
#	print Data::Dumper::Dumper(%fields);
	return %fields;
}

1
