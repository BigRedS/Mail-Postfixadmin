#! /usr/bin/perl

use strict;
use 5.010;
use DBI;
use Data::Dumper;
use Crypt::PasswdMD5;	# libcrypt-passwdmd5-perl

##Todo: detect & support different password hashes

=pod

=head1 Vpostmail.pm

A module for interfering with a Postfix/Dovecot/MySQL system

=head1 Synopsis

	my $d = Vpostmail->new();
	$d->setDomain("example.org");
	$d->createDomain();
	$d->setUser("foo@example.org");
	$d->createUser;

	my %dominfo = $d->getDomainInfo();


=head1 Description

Vpostmail is an attempt to provide a whole bunch of neat functiosn that wrap around the tedious SQL involved
in interfering with a Postfix/Dovecot/MySQL virtual mailbox mail system. It can probably be used on others
so long as the DB schema is similar enough.

It's _very_much_ still in development. All sorts of things will change :)

=cut

package Vpostmail;
sub new() {
	my $class = shift;
	my $self = {};
	bless($self,$class);
	$self->{dbi} = &_dbConnection('/etc/postfix/main.cf');
	$self->{configFiles}->{'postfix'} = '/etc/postfix/main.cf';
	my %_tables = &_tables;
	$self->{tables} = \%_tables;
	my %_fields = &_fields;
	$self->{fields} = \%_fields;
	return $self;
}

=pod

=item getTables() and setTables(), and getFields() and setFields()

Internally, the db schema is stored in two hashes. 

%_tables is a hash storing the names of the tables. The keys are the values used internally to refer to the 
tables, and the values are the names of the tables in the db.

%_fields is a hash of hashes. The 'top' hash has as keys the internal names for the tables (as found in 
getTables), with the values being hashes representing the tables. Here, the key is the name as used internally, 
and the value the names of those fields in the SQL.

getFields returns %_fields, getTables %_tables. setFields and setTables resets them to the hash passed as an 
argument. It does not merge the two hashes.

This is the only way you should be interfering with those hashes.

Since the module does no guesswork as to the db schema (yet), you might need to use these to get it to load 
yours. Even when it does do that, it might guess wrongly.

=cut

sub getTables(){
	my $self = shift;
	return $self->{tables}
}
sub getFields(){
	my $self = shift;
	return $self->{fields}
}

sub setTables(){
	my $self = shift;
	$self->{tables} = @_;
	return $self->{tables};
}

sub setFields(){
	my $self = shift;
	$self->{fields} = @_;
	return $self->{fields};
}

=pod 

=item getDomain() and setDomain(), and getUser() and setUser()

Anything that operates on a domain or a user will expect the object's user or domain to have already been set with 
one of these. setUser may either be passed the full username (bob@example.org) or, if a domain is already set, just 
the left-hand-side (bob). These two are equivalent:

$d->setDomain('example.org');
$d->setUser('bob');

$d->setUser('bob@example.org');

Note that this behaviour depends upon the argument to setUser, not only the set-ness of a domain. If no domain is 
set, then the argument to setUser is always assumed to be the whole username.
If a domain is set, then if the argument to SetUser contains an '@' it is assumed to be the whole username, else only
the left hand side. 

The setters return the value they've set, so these are equivalent:

  $d->setDomain('example.org');
  print $d->getDomain();

  print $d->setDomain('example.org');

in that both will print 'example.org'

=cut

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

=item unsetDomain() and unsetUser()

Sets the domain or the user to undef. Returns the previous value of the variable, rather than the set variable,
as per the setters. So:

  $d->setDomain('example.org')
  print $d->setDomain(undef);

will print undef, whereas

  $d->setDomain('example.org)
  print $d->unsetDomain();

will print 'example.org'

=cut

sub unsetDomain(){
	my $self = shift;
	my $return = $self->{_domain};
	$self->{_domain} = undef;
	return $return;
}


sub unsetUser(){
	my $self = shift;
	my $return = $self->{_domain};
	$self->{_domain} = undef;
	return $return;
}

=item numDomains()

Returns the number of domains configured on the server. Will, one day, accept a regular expression as an argument
and only return the number of domins that match that pattern.

=cut

##Todo: Accept a regex to match
sub numDomains(){
	my $self = shift;
	my $query = "select count(*) from $self->{tables}->{domain}";
	my $numDomains = ($self->{dbi}->selectrow_array($query))[0];
	$numDomains--;	# since there's an 'ALL' domain in the db
	$self->{_numDomains} = $numDomains;
	return $self->{_numDomains};
}

=item numUsers()

Returns the number of configured users. If a domain is set (with setDomain() ) it will only return users 
configured on that domain. If not, it will return all the users.

If passed a regex, it should (but doesn't yet) only return the part of that list that matches the regex.

=cut

##Todo: make the above true
sub numUsers(){
	my $self = shift;
	my $query;
	my $domain = $self->{_domain};

	if ($domain){
		$query = "select count(*) from `$self->{tables}->{alias}` where $self->{fields}->{alias}->{domain} = \'$self->{_domain}\'"
	}else{
		$query = "select count(*) from `$self->{tables}->{alias}`";
	}
	my $numUsers = ($self->{dbi}->selectrow_array($query))[0];
	return $numUsers;
	return $query;
}

=item listDomains() and listUsers()

Work in the same way as their count counterparts above, but return the list rather than the count.

=cut

##Todo: make the above line true
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
	$sth->execute;
	my @users;
	while(my @row = $sth->fetchrow_array()){
		push(@users, $row[0]);
	}
	return @users;


}

=item domainExists() and userExists()

Checks for the existence of a user or a domain. Accepts no arguments - the user or domain should be set with setUser() or 
setDomain()

When it does accept an argument, it will be a hash of search terms, the precise mechanics of which I've yet to decide upon.

=cut

sub domainExists(){
	my $self = shift;
	my $domain;
	$domain = $self->{_domain};
	my $query = "select count(*) from $self->{tables}->{domain} where $self->{fields}->{domain}->{domain} = \'$domain\'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	return $count
}

sub userExists(){
	my $self = shift;
	my $user;
	$user = $self->{user};
	my $query = "select count(*) from $self->{tables}->{mailbox} where $self->{fields}->{mailbox}->{username} = \'$user\'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	return $count
}


=item getUserInfo()

Returns a hash containing info about the user. The keys are the same as the internally-used names for the fields
in the SQL (as you can find from getFields and getTables).

The hash keys are essentially the same as those found by getFields:

	username	The username. Hopefully redundant.
	password	The crypted password of the user
	name		The human name associated with the username
	domain		Teh domain the user is associated with
	local_part	The local part of the email address
	maildir		The path to the maildir *relative to the maildir root configured in Postfix/Dovecot*
	active		Whether or not the user is active
	created		Creation data
	modified	Last modified data


User needs to have been set by setUser() previously.

=cut

sub getUserInfo(){
	my $self = shift;
	my $user;
	$user = $self->{_user};
	my %userinfo;
	my $query = "select * from `$self->{tables}->{mailbox}` where $self->{fields}->{mailbox}->{username} = '$user'";
	my $userinfo = $self->{dbi}->selectrow_hashref($query);


	# we want to return a hash using the names of the fields we use internally
	# in pursuit of consistency of output, but we'll be given them as named
	# in the db here. We do, however, have a hash defining these. Here, we create
	# a new hash, effectively renaming the keys in the hash returned by DBI with 
	# those found by looking up in the $self->{fields}->{mailbox} 
	my %return;
	my %mailboxHash = %{$self->{fields}->{mailbox}};
	my ($k,$v);
	while( ($k,$v) = each( %{$self->{fields}->{mailbox}})){
		my $myname = $k;
		my $theirname = $v;
		my $info = $$userinfo{$theirname};
		$return{$myname} = $info;
	}

	return %return;
}



=item getDomainInfo()

Returns a hash containing info about the domain. The keys are the same as the internally-used names for the fields
in the SQL (as you can find from getFields and getTables), with a couple of additions:


	domain		The domain name (hopefully redundant)
	description	Content of the description field
	quota		Mailbox size quota
	transport	Postfix transport (usually virtual)
	active		Whether the domain is active or not
	backupmx0	Whether this is a  backup MX for the domain
	mailboxes	Array of mailbox usernames associated with the domain (note: the full username, not just the local part)
	modified	last modified date 
	num_mailboxes   Count of the mailboxes (effectively, the length of the array in mailboxes)
	created		Creation data
	dominfo_query   The query used to get the domain info
	aliases		Alias quota for the domain
	maxquota	Mailbox quota for teh domain
	mailbox_query	Query used to get the mailboxes for the domain


Domain needs to have been set by setDomain() previously.

=cut

sub getDomainInfo(){
	my $self = shift;
	my $domain;
	if($self->{_domain}){
		$domain = $self->{_domain};
	}else{
		$domain = shift;
	}
	my %domiaininfo;
	my $query = "select * from `$self->{tables}->{domain}` where $self->{fields}->{domain}->{domain} = '$domain'";
	my $domaininfo = $self->{dbi}->selectrow_hashref($query);

	
	# This is exactly the same data acrobatics as getUserInfo() above, to get consistent
	# output:
	my %return;
	my %domainhash = %{$self->{fields}->{domain}};
	my ($k,$v);
	while ( ($k,$v) = each ( %{$self->{fields}->{domain}} ) ){
		my $myname = $k;
		my $theirname = $v;
		my $info = $$domaininfo{$theirname};
		$return{$myname} = $info;
	}
	$return{dominfo_query}=$query;

	$query = "select username from `$self->{tables}->{mailbox}` where $self->{fields}->{mailbox}->{domain} = '$domain'";

	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my @mailboxes;
	while (my @rows = $sth->fetchrow()){
		push(@mailboxes,$rows[0]);
	}
	
	$return{mailboxes} = \@mailboxes;
	$return{num_mailboxes} = scalar @mailboxes;
	$return{mailbox_query}=$query;
	
	return %return;
}



=item cryptPassword() and changePassword()

changePassword changes the password of a user. The user should be set with setUser and the cleartext password 
passed as an argument. It returns the encrypted password as written to the DB. 
The salt is picked at pseudo-random; successive runs will (should) produce different results.

cryptPassword probably has no real use. It should let you specify a salt for the password, but doesn't yet. It 
expects a cleartext password as an argument, and returns the crypted sort. 

=cut

sub cryptPassword(){
	my $self = shift;
	my $password = shift;
	my $cryptedPassword = Crypt::PasswdMD5::unix_md5_crypt($password);
	return $cryptedPassword;
}

sub changePassword(){
	my $self = shift;
	my $user = $self->user;
	my $password = shift;

	
	my $cryptedPassword = $self->cryptPassword($password);

	my $query = "update `$self->{tables}->{mailbox}` set `$self->{fields}->{mailbox}->{password}`=? where `$self->{fields}->{mailbox}->{username}`='$user'";

	my $sth = $self->{dbi}->prepare($query);
	$sth->execute($cryptedPassword);
	return $cryptedPassword;
}

=item addDomain()

Should work like addUser but doesn't. Accepts a hash of setings, but doesn't really care what they are.

=cut

sub addDomain(){
	my $self = shift;
	my %options = @_;
	my $fields;
	my $values;
	$options{modified} = $self->_mysqlNow;
	$options{created} = $self->_mysqlNow;
	foreach(keys(%options)){
		$fields.= $self->{fields}->{domain}->{$_}.", ";
		$values.= "'$options{$_}', ";;
	}
	$fields =~ s/, $//;
	$values =~ s/, $//;
	my $query = "insert into `$self->{tables}->{domain}` ";
	$query.= " ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();	
}

=item adduser()

Expects to be passed a hash of options. Allowed ones are:

 userame		the login username
 password_plain		plain text password
 password_crypt 	already crypted password
 name			real name of the associated human
 maildir		path to the maildir relative to the root configured in Dovecot/Postfix
 quota			max mailbox size
 local_part		the left hand side of the address
 domain			the right hand side of the address
 created		creation date timestamp
 modified		last modified timestamp
 active			whether or not the domain is to be used. 1=active, 0=inactive

The only necessary one is 'username'.

If both password_plain and password_crypt are passed, password_crypt will be used. If only password_plain 
is passed it will be crypted with cryptPasswd()

Defaults are mostly sane where values aren't explicitly passed:

=over

=item * password and name each default to null

=item * maildir is created by appending a '/' to the username

=item * quota adheres to MySQL's default (which is normally zero, meaning infinite)

=item * local_part is the part to the left of the '@' in the username

=item * domain is the part after the '@' of the username

=item * created is set to now

=item * modified is set to now

=item * active adheres to MySQL's default (which is normally '1')

=back

These are only set if they fail an exists() test; if undef is passed, it will not be clobbered - null 
will be written to MySQL and it will take care of any defaults.

=cut

sub addUser(){
	my $self = shift;
	my %opts = @_;
	my $fields;
	my $values;

	if($opts{password_crypt}){
		$opts{password} = $opts{password_crypt};
	}elsif($opts{password_clear}){
		$opts{password} = $self->cryptPassword($opts{password_clear});
	}

	unless(exists $opts{maildir}){
		$opts{maildir} = $opts{username}."/";
	}
	unless(exists $opts{local_part}){
		if($opts{username} =~ /^(.+)\@/){
			$opts{local_part} = $1;
		}
	}
	unless(exists $opts{domain}){
		if($opts{username} =~ /\@(.+)$/){
			$opts{domain} = $1;
		}
	}
	unless(exists $opts{created}){
		$opts{created} = $self->_mysqlNow;
	}
	unless(exists $opts{modified}){
		$opts{modified} = $self->_mysqlNow;
	}
	foreach(keys(%opts)){
		unless( /_(clear|cryp)$/){
			$fields.= $self->{fields}->{mailbox}->{$_}.", ";
			$values.= "'$opts{$_}', ";
		}
	}
	$values =~ s/, $//;
	$fields =~ s/, $//;
	my $query = "insert into `$self->{tables}->{mailbox}` ";
	$query.= " ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();	
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
				'address'	=> 'address',
				'domain'	=> 'domain'
	};
	$fields{'domain'} = { 
	                        'domain'        => 'domain',
				'description'	=> 'description',
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
	                        'username'      => 'username',
				'password'	=> 'password',
				'name'		=> 'name',
				'maildir'	=> 'maildir',
				'quota'		=> 'quota',
				'local_part'	=> 'local_part',
				'domain'	=> 'domain',
				'created'	=> 'created',
				'modified'	=> 'modified',
				'active'	=> 'active'
	};
	$fields{'domain_admins'} = {
	                        'domain'        => 'domain',
	                        'username'      => 'username'
	};
	return %fields;
}

# Returns a timestamp of its time of execution in a format ready for inserting into MySQL
# (YYYY-MM-DD hh:mm:ss)
sub _mysqlNow() {
	
	my ($y,$m,$d,$hr,$mi,$se)=(localtime(time))[5,4,3,2,1,0];
	my $date = $y + 1900 ."-".sprintf("%02d",$m)."-$d";
	my $time = "$hr:$mi:$se";
	return "$date $time";
}

1
