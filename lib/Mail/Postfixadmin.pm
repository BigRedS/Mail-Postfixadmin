#! /usr/bin/perl


package Mail::Postfixadmin;

use strict;
use 5.010;
use DBI;		# libdbi-perl
use Crypt::PasswdMD5;	# libcrypt-passwdmd5-perl
use Carp;
use Data::Dumper;

our $VERSION;
$VERSION = "0.0.20111229";

=pod

=head1 NAME

Mail::Postfixadmin - Interferes with a Postfix/MySQL virtual mailbox system

=head1 SYNOPSIS

Mail::Postfixadmin is an attempt to provide a bunch of functions that wrap
around the tedious SQL involved in interfering with a Postfix/Dovecot/MySQL 
virtual mailbox mail system.

It's _very_much_ still in development. All sorts of things will change :) This 
is currently a todo list as much as it is documentation of the module.

This is also completely not an object-orientated interface to the 
Postfix/Dovecot mailer, since it doesn't actually represent anything sensibly 
as objects. At best, it's an object-considering means of configuring it.

        use Mail::Postfixadmin;

	my $p = Mail::Postfixadmin->new();
	$p->createDomain(
		domain        => 'example.org',
	        description   => 'an example',
		num_mailboxes => '0',
	);

	$p->createUser(
		ussername      => 'avi@example.com',
		password_plain => 'password',
		name           => 'avi',
	);

	my %dominfo = $p->getDomainInfo();

	my %userinfo = $p->getUserInfo();

	$p->changePassword('avi@example.com', 'complexpass');


=head1 CONSTRUCTOR AND STARTUP

=head2 new()

Creates and returns a new Mail::Postfixadmin object. You want to provide some 
way of determining how to connect to the database; there are three ways, listed 
in order of precedence (i.e. the third overrules the second which overrules the
first):

Firstly, you may pass nothing to the constructor, and have it parse 
/etc/postfix/main.cf:

  my $v = Mail::Postfixadmin->new();

Secondly, you may pass C<dbi>, C<dbuser> and C<dbpass> which are essentially the
three arguments to a C<DBI-E<gt>connect> (they are used for exactly this):

  my $v = Mail::Postfixadmin->new(
         dbi	=> 'DBI:mysql:dbname',
	 dbuser	=> 'username',
	 dbpass => 'password'
  );

Thirdly, you may pass a path to main.cf to the constructor, and have it parse 
that file to find a file specifying the file in which to find Postfix's MySQL 
configuration and then parse *that* file to get the credentials:

 my $v = Mail::Postfixadmin->new(
 	 maincf	=> '/etc/postfix/main.cf'
 );


If C<main.cf> is passed, the C<dbi>, C<dbuser> and C<dbpass> values are ignored 
and overwritten by data found in the files. C<main.cf> is deemed to have been 
'passed' if its value contains a forward-slash ('C</>').

=head3 Password storage

By default, passwords are crypted with Crypt::PasswdMD5 and stored in the 
C<password> field of the relevant table. Optionally, you may also have them 
stored in cleartext and/or PGP-encrypted forms.

To do this you need to set the C<storeCleartextPassword> and/or 
C<storeGPGPassword> keys to a non-zero value and make sure you have the correct
fields in your DB; cleartext passwords need a C<password_clear> field and GPG 
ones a C<password_gpg> field in the C<mailbox> table. GPG passwords also require 
an appropriately configured GPG keyring.

=head4 GPG Passwords

There's a number of other keys for GPG password storage:

  gpgSecretKey  The ID of the secret key.
  gpgRecipient  One of the ID fields of the public key.
  gpgBinary	Optional, path to the GPG binary. Defaults to /usr/bin/gpg
  gpgPassphrase Passphrase for the key(s).

A complete example might read:

  my $v = Mail::Postfixadmin->new(
        storeGPGPassword => 1,
	gpgBinary     => '/usr/local/bin/gpg',
        gpgSecretKey  => '102FC956',
        gpgRecipient  => 'postfixadmin@avi.co',
        gpgPassphrase => 'Ue5gi2sei',
  );

Each of these appear as attributes of the object with the same name so you can, 
for example, change the key used later on with:

  $p->gpgSecretKey("102FC958");


);


=cut


sub new() {
	my $class = shift;
	my %params = @_;
	my $self = {};
	foreach(keys(%params)){
		$self->{_params}->{$_} = $params{$_};
	}
	# Set some variables for future use:
	$self->{version} = $VERSION;
	# This is a hash-of-hashes we use to store the table names
	my %_tables = &_tables;
	$self->{tables} = \%_tables;
	# And a hash of hashes of hashes we use to store the field names
	my %_fields = &_fields;
	$self->{fields} = \%_fields;
	# Dovecot config:
	my @doveconf;
	eval{
		@doveconf = qx@doveconf 2>/dev/null@ or die "$!";
	};
	$self->{'_doveconf'} = \@doveconf unless($@);

	# Postfix config:
	my @postconf;
	eval{
		@postconf = qx@postconf 2>/dev/null@ or die "$!";
	};
	$self->{'_postconf'} = \@postconf unless($@);

	# Here we build a DBI object using whatever DB credentials we can find:
	my @_dbi;
	unless(exists($self->{'_params'}->{'dbi'})){
		print "dbi param not sent\n";
		if($self->{_params}->{mysqlconf} =~ m@/@){
			@_dbi = _parseMysqlConfigFile($self->{_params}->{mysqlconf});
		}else{
			unless(exists($self->{_params}->{maincf})){
				$self->{_params}->{maincf} = '/etc/postfix/main.cf';
			}
			@_dbi = _parsePostfixConfigFile($self->{_params}->{maincf});
		}	
		$self->{_params}->{dbi} = $_dbi[0];
		$self->{_params}->{dbuser} = $_dbi[1];
		$self->{_params}->{dbpass} = $_dbi[2];
	}
	$self->{dbi} = DBI->connect(
		$self->{_params}->{dbi},
		$self->{_params}->{dbuser},
		$self->{_params}->{dbpass}
	);
	if (!$self->{dbi}){
		Carp::croak "No dbi object created";
	}

	
	# And now check whether we're supposed to be storing cleartext passwords and,
	# if so, whether we're able to:
	$self->{storeCleartextPassword} = $self->{'_params'}->{'storeCleartextPassword'} || 0;
	if($self->{storeCleartextPassword} == 1){
		my $dbName = (split(/:/, $self->{'_params'}->{'dbi'}))[2];
		my $tableName = $self->{'tables'}->{'mailbox'};
		my $fieldName = $self->{'fields'}->{'mailbox'}->{'password_clear'};
		unless(_fieldExists($self->{'dbi'}, $dbName, $tableName, $fieldName)){
			Carp::croak "storeCleartextPassword set to non-zero but table '$tableName' has no field '$fieldName' to store cleartext passwords in";
		}
	}

	# And the same for GPG passwords
	$self->{'storeGPGPassword'} = $self->{'_params'}->{'storeGPGPassword'} || 0;
	if ($self->{'storeGPGPassword'} > 0){
		my $dbName = (split(/:/, $self->{'_params'}->{'dbi'}))[2];
		my $tableName = $self->{'tables'}->{'mailbox'};
		my $fieldName = $self->{'fields'}->{'mailbox'}->{'password_gpg'};
		if (_fieldExists($self->{'dbi'}, $dbName, $tableName, $fieldName)){
			# If we are supposed to be storing GPG passwords, we need the
			# appropriate module.
			if (eval {require Crypt::GPG}){
				Crypt::GPG->import();
			}else{
				Carp::croak "Error require()ing Crypt::GPG to allow support for storeGPGPassword:\n$@";
			}
			my $gpg = new Crypt::GPG;
			$self->{'gpgRecipient'} = $self->{'_params'}->{'gpgRecipient'};
			if ($self->{'gpgRecipient'} !~ /.+/){
				Carp::croak "GPG support requires a value for gpgRecipient be passed to the constructor";
			}
			$self->{'_gpgBinary'} = $self->{'_params'}->{'gpgBinary'} || '/usr/bin/gpg';
			unless( -x $self->{'_gpgBinary'}){
				Carp::croak "GPG binary at '$self->{'_gpgbinary'}' either non-existant or not-executable";
			}
			$gpg->gpgbin($self->{'_gpgBinary'});
			$self->{'gpgSecretKey'} = $self->{'_params'}->{'gpgSecretKey'} || Carp::croak "storeGPGpassword set but gpgSecretKey not set";
			unless($gpg->keydb($self->{'gpgRecipient'})){
				Carp::croak "No key with identifier '$self->{'gpgRecipient'}' in db";
			}

			$self->{'gpg'} = $gpg;
		}else{
			Carp::croak "storeGPGPassword is set non-zero but table '$tableName' has no field '$fieldName' to store GPG-encrypted passwords in";
		}


	}
#	$self->{mailLocation} = (reverse(grep(/\s*mail_location/, qx/$self->{_doveconf}/)))[0];
#	chomp $self->{mailLocation};
	bless($self,$class);
	return $self;
}


=head1 METHODS

=cut 

#=head2 User and domain information
#
#=head3 numDomains()
#
#Returns the number of domains configured on the server. If you'd like only 
#those that match some pattern, you should use C<getDomains()> and measure the 
#size of the returned list.
#
#=cut
#
#
#sub numDomains(){
#	my $self = shift;
#	my $query = "select count(*) from $self->{tables}->{domain}";
#	my $numDomains = ($self->{dbi}->selectrow_array($query))[0];
#	$numDomains--;	# since there's an 'ALL' domain in the db
#	$self->{_numDomains} = $numDomains;
#	$self->{infostr} = $query;
#	return $self->{_numDomains};
#}
#
#
#=head3 numUsers()
#
#Returns the number of configured users. If a domain is passed as an argument it 
#will only return users configured on that domain. If not, it will return a 
#count of all users on the system
#
#=cut
#
#sub numUsers(){
#	my $self = shift;
#	my $query;
#	my $domain = shift;
#	if ($domain){
#		$query = "select count(*) from `$self->{tables}->{mailbox}` where $self->{fields}->{mailbox}->{domain} = \'$domain}\'"
#	}else{
#		$query = "select count(*) from `$self->{tables}->{mailbox}`";
#	}
#	my $numUsers = ($self->{dbi}->selectrow_array($query))[0];
#	$self->{infostr} = $query;
#	return $numUsers;
#}
#

=head3 getDomains() 

Returns an array of domains on the system. This is all domains for
which the system will accept mail, including aliases.

You can pass a pattern as the argument to get only domains matching 
that pattern:

  @domains = $getDomains('com$');

=cut

sub getDomains(){
	my $self = shift;
	my $regex = shift;
	my @results;
	@results = $self->_dbSelect(
		table => 'domain',
		fields => [ "domain" ],
	);
	if($regex){
		@results = grep (/$regex/, @results);
	}
	my @domains = map ($_->{'domain'}, @results);
	return @domains;
}

=head3 getDomainsAndAliases()

Returns a hash describing all domains on the system. Keys are domain names
and values are the domain for which the key is an alias, where appropirate.

As with getDomains, accepts a regex pattern as an argument.

  %domains = getDomainsAndAliases('org$');
  foreach(keys(%domains)){
	if($domains{$_} =~ /.+/){
		print "$_ is an alias of $domains{$_}\n";
	}else{
		print "$_ is a real domain" unless $domains{$_};
	}
  }

=cut

sub getDomainsAndAliases(){
	my $self = shift;
	my $regex = shift;
	my @domains = $self->getDomains($regex);
	# prepend a null string so that we definitely get a domain every odd-
	# numbered element of the list map returns, else the hash looks a bit
	# weird
	my %domainsWithAliases = map {$_ => "".$self->getAliasDomainTarget($_)} @domains;
	return %domainsWithAliases;
}

=head3 getUsers()

Returns a list of all users. If a domain is passed, only returns users on that domain.

You can pass a pattern as the argument to get only users matchin that pattern.

  @users = getUsers('example.org');

=cut

sub getUsers(){
	my $self = shift;
	my $domain = shift;
	my (@users,@aliases);
	@users = $self->getRealUsers($domain), $self->getAliasUsers($domain);
	return @users;
}

=head3  getUsersAndAliases()

Returns a hash describing all users on the system. Keys are users and values are
their targets.

as with C<getUsers>, accepts a pattern to match.

  %users = getUsersAndAliases('example.org');
  foreach(keys(%users)){
	if($users{$_} =~ /.+/){
		print "$_ is an alias of $users{$_}\n";
	}else{
		print "$_ is a real mailbox" unless $users{$_};
	}
  }
=cut

sub getUsersAndAliases(){
	my $self = shift;
	my $regex = shift;
	my @users = $self->getUsers($regex);
	# prepend a null string so that we definitely get a domain every odd-
	# numbered element of the list map returns, else the hash looks a bit
	# weird
	my %usersWithAliases = map {$_ => "".$self->getAliasUserTarget($_)} @users;
	return %usersWithAliases;
}

=head3 getRealUsers() 

Returns a list of real users (i.e. those that are not aliases). If a domain is
passed, returns only users on that domain, else returns a list of all real 
users on the system.

  @realUsers = getRealUsers('example.org');

=cut

sub getRealUsers(){
	my $self = shift;
	my $domain = shift;
	my $query;
	my @results;
	if ($domain =~ /.+/){
		@results = $self->_dbSelect(
			table  => 'mailbox',
			fields => [ 'username' ],
			equals => [ 'domain', $domain],
		);
	}else{
		@results = $self->_dbSelect(
			table  => 'alias',
			fields => [ 'address' ],
			equals => [ 'goto', ''],
		);
	}
	my @users;
	@users = map ($_->{'username'}, @results);
	return @users;
}

=head3 getAliasUsers()

Returns a list of alias users on the system or, if a domain is passed as an argument, 
the domain.

  my @aliasUsers = $p->getAliasUsers('example.org');

=cut

#TODO: getAliasUsers to return a hash of Alias=>Target

sub getAliasUsers() {
	my $self = shift;
	my $domain = shift;
	my @results;
	if ( $domain ){
		my $like = '%'.$domain; 
		@results = $self->_dbSelect(
			table  => 'alias',
			fields => ['address'],
			like   => [ 'goto' , $like ] ,
		);
	}else{
		@results = $self->_dbSelect(
			table => 'alias',
			fields => ['address'],
		);
	}
	my @aliases = map ($_->{'address'}, @results);
	return @aliases;
}

=head3 domainExists()

Check for the existence of a domain. Returns the number found (in anticipation of 
also serving as a sort-of search) if the domain does exist, undef otherwise.

  if($p->$domainExists('example.org')){
  	print "example.org exists!\n";
  }	

=cut

sub domainExists(){
	my $self = shift;
	my $domain = shift;
	my $regex = shift;
	if ($domain eq ''){
		Carp::croak "No domain passed to domainExists";
	}
	if($self->domainIsAlias($domain) > 0){
		return $self->domainIsAlias($domain);
	}
	my $query = "select count(*) from $self->{tables}->{domain} where $self->{fields}->{domain}->{domain} = \'$domain\'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	$self->{infostr} = $query;
	if ($count > 0){
		return $count;
	}else{
		return;
	}
}

=head3 userExists()

Check for the existence of a user. Returns the number found (in anticipation of 
also serving as a sort-of search) if the user does exist, empty otherwise.

  if($p->userExists('user@example.com')){
  	print "user@example.com exists!\n";
  }


=cut 

sub userExists(){
	my $self = shift;
	my $user = shift;


	if ($user eq ''){
		Carp::croak "No username passed to userExists";
	}

	if ($self->userIsAlias($user)){
		return $self->userIsAlias($user);
	}
	my $query = "select count(*) from $self->{tables}->{mailbox} where $self->{fields}->{mailbox}->{username} = '$user'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	$self->{infostr} = $query;
	if ($count > 0){
		return $count;
	}else{
		return;
	}
}

=head3 domainIsAlias()

Returns true if the argument is a domain which is an alias (i.e. has a target). 

Actually returns the number of aliases the domain has.

  if($p->domainIsAlias('example.net'){
      print 'Mail for example.net is forwarded to ". getAliasDomainTarget('example.net');
  }

=cut

sub domainIsAlias(){
	my $self = shift;
	my $domain = shift;

	Carp::croak "No domain passed to domainIsAlias" if $domain eq '';

	my $query = "select count(*) from $self->{tables}->{alias_domain} where $self->{fields}->{alias_domain}->{alias_domain} = '$domain'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	$self->{infostr} = $query;
	if ($count > 0){
		return $count;
	}else{
		return;
	}
}

=head3 getAliasDomainTarget()

Returns the target of a domain if it's an alias, undef otherwise.

  if($p->domainIsAlias('example.net'){
      print 'Mail for example.net is forwarded to ". getAliasDomainTarget('example.net');
  }

=cut

sub getAliasDomainTarget(){
	my $self = shift;
	my $domain = shift;
	if ($domain eq ''){
		Carp::croak "No domain passed to getAliasDomainTarget";
	}
	unless ( $self->domainIsAlias($domain) ){
		return;
	}
	my @output = $self->_dbSelect(
		table  => 'alias_domain',
		fields => [ 'target_domain' ],
		equals => [ 'alias_domain', $domain ],
	);
	my %result = %{$output[0]};
	return $result{'target_domain'};
}
		

#=head3 domainIsTarget()
#
#Checks whether the domain passed is the target of an alias domain. Returns the 
#number of aliases that have the set domain as their targets, undef if none are 
#found.
#
#=cut
#
#sub domainIsTarget(){
#	my $self = shift;
#	my $domain = shift;
#	if ($domain eq ''){
#		Carp::croak "No domain passed to domainIstarget";
#	}
#	my $query = "select count(*) from $self->{tables}->{alias_domain} where $self->{fields}->{alias_domain}->{target_domain} = '$domain'";
#	my $sth = $self->{dbi}->prepare($query);
#	$sth->execute;
#	my $count = ($sth->fetchrow_array())[0];
#	$self->{infostr} = $query;
#	if ($count > 0){
#		return $count;
#	}else{
#		return;
#	}
#}

=head3 userIsAlias()

Checks whether a user is an alias to another address.

  if($p->userIsAlias('user@example.net'){
      print 'Mail for user@example.net is forwarded to ". getAliasUserTarget('user@example.net');
  }

=cut

sub userIsAlias{
	my $self = shift;
	my $user = shift;
	if ($user eq ''){ Carp::croak "No user passed to userIsAlias";}
	my $query = "select count(*) from $self->{tables}->{alias} where $self->{fields}->{alias}->{address} = '$user'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	$self->{infostr} = $query;
	if ($count > 0){
		return $count;
	}else{
		return;
	}
}

#=head3 userIsTarget()
#
#Checks whether the passed user is a target for an alias user. Returns the number 
#of rows in which the user is configured as an alias (which should be the number 
#of unique addresses, but may not be. Use C<getUserAliases()> for a more 
#accurate count), undef if it's not a target.
#
#=cut
#
#sub userIsTarget{
#	my $self = shift;
#	my $user = shift;
#	if ($user eq ''){ Carp::croak "No user passed to userIsTarget";}
#	my @results = $self->_dbSelect(
#		count => 'true',
#		like  => ['goto', "%$user%"],
#		table => 'alias'
#	);
#	my %row = %{$results[0]};
#	my $count = $row{'count(*)'};
#	if ($count > 0){
#		return $count;
#	}else{
#		return;
#	}
#}

#=head3 getUserAliases()
#
#Returns a list of aliases for which the passed user is a target.
#
# my @aliasAddresses = getUserAliases($address);
#
#=cut
#
#sub getUserAliases{
#	my $self = shift;
#	my $user = shift;
#	if ($user eq ''){ Carp::croak "No user passed to getUserAliases";}
#	my $query = "select $self->{fields}->{alias}->{address} from $self->{tables}->{alias} where $self->{fields}->{alias}->{goto} like '%user%'";
#	my $sth = $self->{dbi}->prepare($query);
#	$sth->execute;
#	my @addresses;
#	while(my @row = $sth->fetchrow_array()){
#		push(@addresses, $row[0]);
#	}
#	return @addresses;
#}

=head3 getAliasUserTargets()

Returns an array of addresses for which the current user is an alias.
  
 my @targets = $p->getAliasUserTargets($user);

  if($p->domainIsAlias('user@example.net'){
      print 'Mail for example.net is forwarded to ". join(", ", getAliasDomainTarget('user@example.net'));
  }


=cut 

sub getAliasUserTargets{
	my $self = shift;
	my $user = shift;
	if ($user eq ''){ Carp::croak "No user passed to getAliasUserTargetArray";}

	my @gotos = $self->_dbSelect(
		table	=> 'alias',
		fields	=> ['goto'],
		equals	=> [ 'address', $user ],
	);
	return @gotos;
}

=head3 getUserInfo()

Returns a hash containing info about the user:

	username	Username. Should be an email address.
	password	The crypted password of the user
	name		The human name associated with the username
	domain		The domain the user is associated with
	local_part	The local part of the email address
	maildir		The path to the maildir *relative to the maildir root 
			configured in Postfix/Dovecot*
	active		Whether or not the user is active
	created		Creation date
	modified	Last modified data

Returns undef if the user doesn't exist.

=cut

sub getUserInfo(){
	my $self = shift;
	my $user = shift;
	Carp::croak "No user passed to getUserInfo" if $user eq '';
	return unless $self->userExists($user);
	my %userinfo;
	my @results = $self->_dbSelect(
		table  => 'mailbox',
		fields => ['*'],
		equals => ['username', $user]
	);
	return @results;
}

=head3 getDomainInfo()

Returns a hash containing info about a domain. Keys:

	domain		The domain name
	description	Content of the description field
	quota		Mailbox size quota
	transport	Postfix transport (usually virtual)
	active		Whether the domain is active or not
	backupmx0	Whether this is a  backup MX for the domain
	mailboxes	Array of mailbox names associated with the domain 
			(note: the full username, not just the local part)
	modified	last modified date 
	num_mailboxes   Count of the mailboxes (effectively, the length of the 
			array in `mailboxes`)
	created		Creation data
	aliases		Alias quota for the domain
	maxquota	Mailbox quota for teh domain

Returns undef if the domain doesn't exist.

=cut

sub getDomainInfo(){
	my $self = shift;
	my $domain = shift;

	Carp::croak "No domain passed to getDomainInfo" if $domain eq '';
	return unless $self->domainExists($domain);

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
	$self->{infostr} = $query;
	$query = "select username from `$self->{tables}->{mailbox}` where $self->{fields}->{mailbox}->{domain} = '$domain'";
	$self->{infostr}.=";".$query;
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my @mailboxes;
	while (my @rows = $sth->fetchrow()){
		push(@mailboxes,$rows[0]);
	}
	
	$return{mailboxes} = \@mailboxes;
	$return{num_mailboxes} = scalar @mailboxes;
	
	return %return;
}

#=head3 getTargetAliases()
#
#Returns a list of aliases for the target currently set as the domain. Returns 
#false if the domain is not listed as a target, an empty list if the domain is 
#listed as a target, but the alias is NULL.
#
#=cut
#
#sub getTargetAliases{
#	my $self = shift;
#	my $domain = shift;
#	if ($domain eq ''){ Carp::croak "No domain passed to getTargetAliases"; }
#	my @results = $self->_dbSelect(
#		table  => "alias_domain",
#		fields => ["alias_domain"],
#		equals => ['target_domain', $domain],
#	);
#	my @aliases;
#	foreach my $r (@results){
#		my %row = %{$r};
#		push (@aliases, $row{'alias_domain'});
#	}
#	return @aliases;
#}


=head2 Passwords

=head3 cryptPassword()

This probably has no real use, except for where other functions use it. It 
should let you specify a salt for the password, but doesn't yet. It expects a 
cleartext password as an argument, and returns the crypted sort. 

=cut

sub cryptPassword(){
	my $self = shift;
	my $password = shift;
	my $cryptedPassword = Crypt::PasswdMD5::unix_md5_crypt($password);
	return $cryptedPassword;
}

=head3 cryptPasswordGPG()

Encrypts a password with GPG. Only likely to work if storeGPGPasswords is set to a 
non-zero value but happy to try without it.

=cut

sub cryptPasswordGPG(){
	my $self = shift;
	my $password = shift;
	my $gpg = $self->{'gpg'};
	$gpg->passphrase('');
	return join("\n", $gpg->encrypt($password, $self->{'gpgRecipient'}));
}

=head3 cryptPasswordGPG()

Decrypts a password with GPG. Only likely to work if storeGPGPasswords is set to a 
non-zero value but happy to try without it.

=cut

sub decryptPasswordGPG(){
	my $self = shift;
	my $ciphertext = shift;
	my $gpg = $self->{'gpg'};
	$gpg->secretkey($self->{'gpgSecretKey'});
	my ($plaintext, $signature) = $gpg->verify($ciphertext);
	return $plaintext;
}

=head3 changePassword() 

Changes the password of a user. Expects two arguments, a username and a new
password:

	$p->changePassword("user@domain.com", "password");

The salt is picked at pseudo-random; successive runs will (should) produce 
different results.

=cut

sub changePassword(){
	my $self = shift;
	my $user = shift;
	my $password = shift;
	if ($user eq ''){
		Carp::croak "No user passed to changePassword";
	}
	my $cryptedPassword = $self->cryptPassword($password);
	$self->changeCryptedPassword($user,$cryptedPassword,$password);
	return $cryptedPassword;
}

=head3 changeCryptedPassword()

changeCryptedPassword operates in exactly the same way as changePassword, but it 
expects to be passed an already-encrypted password, rather than a clear text 
one. It does no processing at all of its arguments, just writes it into the 
database.

=cut

sub changeCryptedPassword(){
	my $self = shift;
	my $user = shift;;

	if ($user eq ''){
		Carp::croak "No user passed to changeCryptedPassword";
	}
	my $cryptedPassword = shift;
	my $clearPassword = shift;

	my $query = "update $self->{'tables'}->{'mailbox'} set ";
	$query.="`$self->{'fields'}->{'mailbox'}->{'password'}`= '$cryptedPassword'";
	if($self->{'storeCleartextPassword'} > 0){
		$query.= ", `$self->{'fields'}->{'mailbox'}->{'password_clear'}` = '$clearPassword'";
	}
	if($self->{'storeGPGPassword'} > 0){
		my $gpgPassword = $self->cryptPasswordGPG($clearPassword);
		$query.= ", `$self->{'fields'}->{'mailbox'}->{'password_gpg'}` = '$gpgPassword'";
	}
	$query.="where `$self->{'fields'}->{'mailbox'}->{'username'}` = '$user'";

	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();

	return $cryptedPassword;
}

=head2 Creating things

=head3 createDomain()

Expects to be passed a hash of options, with the keys being the same as those 
output by C<getDomainInfo()>. None are necessary except C<domain>.

Defaults are set as follows:

	domain		None; required.
	description	A null string
	quota		MySQL's default
	transport	'virtual'
	active		1 (active)
	backupmx0	MySQL's default
	modified	now
	created		now
	aliases		MySQL's default
	maxquota	MySQL's default

Defaults are only set on keys that haven't been instantiated. If you set a key 
to the null string, it will not be set to the default - null will be passed to 
the DB and it may set its own default.

On both success and failure the function will return a hash containing the 
options used to configure the domain - you can inspect this to see which 
defaults were used if you like.

If the domain already exists, it will not alter it, instead it will return '2' 
rather than a hash.

=cut

sub createDomain(){
	my $self = shift;
	my %opts = @_;
	my $fields;
	my $values;
	my $domain = $opts{'domain'};

	Carp::croak "No domain passed to createDomain" if $domain !~ /.+/;

	if($domain eq ''){
		Carp::croak "No domain passed to createDomain";
	}

	if ($self->domainExists($domain)){
		$self->{infostr} = "Domain '$domain' already exists";
		return 2;
	}

	$opts{modified} = $self->_mysqlNow unless exists($opts{modified});
	$opts{created} = $self->_mysqlNow unless exists($opts{created});
	$opts{active} = '1' unless exists($opts{active});
	$opts{transport} = 'virtual' unless exists($opts{quota});
	foreach(keys(%opts)){
		$fields.= $self->{fields}->{domain}->{$_}.", ";
		$values.= "'$opts{$_}', ";;
	}
	$fields =~ s/, $//;
	$values =~ s/, $//;
	my $query = "insert into `$self->{tables}->{domain}` ";
	$query.= " ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();	
	$self->{infostr} = $query;
	if($self->domainExists($domain)){
		return %opts;
	}else{
		$self->{errstr} = "Everything appeared to succeed, but the domain doesn't exist";
		return;
	}
}

=head3 createUser()

Expects to be passed a hash of options, with the keys being the same as those 
output by C<getUserInfo()>. None are necessary except C<username>.

If both C<password_plain> and <password_crypt> are in the passed hash, 
C<password_crypt> will be used. If only password_plain is passed it will be 
crypted with C<cryptPasswd()> and then inserted.

Defaults are mostly sane where values aren't explicitly passed:

 username	required; no default
 password	null
 name		null
 maildir 	username with a '/' appended to it
 quota		MySQL default (normally zero, which represents infinite)
 local_part	the part of the username to the left of the first '@'
 domain		the part of the username to the right of the last '@'
 created	now
 modified	now
 active		MySQL's default


On success, returns a hash describing the user. You can inspect this to see 
which defaults were set if you like.

This will not alter existing users. Instead, it returns '2' rather than a hash.

=cut

sub createUser(){
	my $self = shift;
	my %opts = @_;
	my $fields;
	my $values;

	Carp::croak "no username passed to createUser" if $opts{"username"} eq '';
	
	my $user = $opts{"username"};

	if($self->userExists($user)){
		$self->{infostr} = "User already exists ($user)";
		return 2;
	}
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
	if ($opts{username} eq ''){
		Carp::croak "No user passed to createUser";
	}
	$values =~ s/, $//;
	$fields =~ s/, $//;
	my $query = "insert into `$self->{tables}->{mailbox}` ";
	$query.= " ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();	
	$self->{infostr} = $query;
	if($self->userExists($user)){
		return %opts;
	}else{
		$self->{errstr} = "Everything appeared to succeed, but the user doesn't exist";
		return;
	}
}

=head3 createAliasDomain()

Creates an alias domain:

 $p->createAliasDomain( 
 	target => 'target.com',
 	alias  => 'alias.com'
 );

something@target.com. Notably, it does not check that the domain is not already
aliased elsewhere, so you can end up aliasing one domain to two targets which 
is probably not what you want.

You can pass three other keys in the hash, though only C<target> and c<alias> 
are required:
 created	'created' date. Is passed verbatim to the db so should be in a 
 		format it understands.
 modified	Ditto but for the modified date
 active		The status of the domain. Again, passed verbatim to the db, 
 		but probably should be a '1' or a '0'.

=cut


sub createAliasDomain {
	my $self = shift;
	my %opts = @_;
	my $domain = $opts{'alias'};
	my $target = $opts{'target'};

	Carp::croak "No alias passed to createAliasDomain" if $domain !~ /.+/;
	Carp::croak "No target passed to createAliasDomain" if $target !~ /.+/;

	if($self->domainIsAlias($domain)){
		$self->{errstr} = "Domain $domain is already an alias";
		##TODO: createAliasDomain return current target if the domain is already an alias
		return;
	}
	unless($self->domainExists("domain" => $domain)){
		$self->createDomain( "domain" => $domain);
	}
	my $fields = "$self->{fields}->{alias_domain}->{alias_domain}, $self->{fields}->{alias_domain}->{target_domain}";
	my $values = " '$domain', '$opts{target}'";

	$fields.=", $self->{fields}->{alias_domain}->{created}";
	if(exists($opts{'created'})){
		$values.=", '$opts{'created'}'";
	}else{
		$values.=", '".$self->_mysqlNow."'";
	}

	$fields.=", $self->{fields}->{alias_domain}->{modified}";
	if(exists($opts{'modified'})){
		$values.=", '$opts{'modified'}'";
	}else{
		$values.=", '".$self->_mysqlNow."'";
	}
	if(exists($opts{'active'})){
		$fields.=", $self->{fields}->{alias_domain}->{active}";
		$values.=", '$opts{'active'}'";
	}
	my $query = "insert into $self->{tables}->{alias_domain} ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	if($self->domainExists($domain)){
		$self->{infostr} = $query;
		return %opts;

	}else{
		$self->{infostr} = $query;
		$self->{errstr} = "Everything appeared to succeed but the domain doesn't exist";
		return;
	}
}

=head3 createAliasUser()

Creates an alias user:

 $p->createAliasUser( 
 	target => 'target@example.org');
 	alias  => 'alias@example.net
 );

will cause all mail sent to alias@example.com to be delivered to target@example.net. 

You may forward to more than one address by passing a comma-separated string:

 $p->createAliasDomain( 
 	target => 'target@example.org, target@example.net',
 	alias  => 'alias@example.net',
 );

For some reason, the domain is stored separately in the db. If you pass a 
C<domain> key in the hash, this is used. If not a regex is applied to the username 
( C</\@(.+)$/> ). If that doesn't match, it Croaks.

You may pass three other keys in the hash, though only C<target> and C<alias> are required:

 created   'created' date. Is passed verbatim to the db so should be in a format it understands.
 modified  Ditto but for the modified date
 active    The status of the domain. Again, passed verbatim to the db, but probably should be a '1' or a '0'.

In full:

 $p->createAliasUser(
		source   => 'someone@example.org',
		target	 => "target@example.org, target@example.net",
		domain	 => 'example.org',
will cause all mail sent to something@alias.com to be delivered to 
		modified => $p->now;
		created	 => $p->now;
		active   => 1
 );

On success a hash of the arguments is returned, with an addtional key: scalarTarget. This is the 
value of C<target> as it was actually inserted into the DB. It will either be exactly the same as 
C<target> if you've passed a scalar, or the array passed joined on a comma.

=cut


sub createAliasUser {
	my $self = shift;
	my %opts = @_;
	my $user = $opts{"alias"};
	if ($user eq ''){
		Carp::croak "No alias key in hash passed to createAliasUser";
	}
	unless(exists($opts{'target'})){
		Carp::croak "No target key in hash passed to createAliasUser";
	}
	if($self->userExists($user)){
		Carp::croak "User $user already exists (passed as alias to createAliasUser)";
	}
	if($self->userIsAlias($user)){
		Carp::croak "User $user is already an alias (passed to createAliasUser)";
	}
	unless(exists($opts{domain})){
		if($user =~ /\@(.+)$/){
			$opts{domain} = $1;
		}else{
			Carp::croak "Error determining domain from user '$user' in createAliasUser";
		}
	}
	#TODO: createAliasUser should accept an array of targets
	$opts{scalarTarget} = $opts{target};

	my $fields = "$self->{fields}->{alias}->{address}, $self->{fields}->{alias}->{goto}, $self->{fields}->{alias}->{domain}";
	my $values = "\'$opts{alias}\', \'$opts{scalarTarget}\', \'$opts{domain}\'";
	
	$fields.=", $self->{fields}->{alias_domain}->{created}";
	if(exists($opts{'created'})){
		$values.=", '$opts{'created'}'";
	}else{
		$values.=", '".$self->_mysqlNow."'";
	}

	$fields.=", $self->{fields}->{alias_domain}->{modified}";
	if(exists($opts{'modified'})){
		$values.=", $opts{'modified'}";
	}else{
		$values.=",  '".$self->_mysqlNow."'";
	}

	if(exists($opts{'active'})){
		$fields.=", $self->{fields}->{alias_domain}->{active}";
		$values.=", '$opts{'active'}'";
	}
	my $query = "insert into $self->{tables}->{alias} ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	
	if($self->userIsAlias($user)){
		return %opts;
	}else{
		return;
	}

}

=head2 Deleting things

=head3 removeUser();

Removes the passed user;

Returns 1 on successful removal of a user, 2 if the user didn't exist to start with.

C<infostr> is set to the query run only if the user exists. If the user doesn't exist, no query is run
and C<infostr> is set to "user doesn't exist (<user>)";

=cut

##Todo: Accept a hash of field=>MySQL regex with which to define users to delete
sub removeUser(){
	my $self = shift;
	my $user = shift;
	if($user eq ''){
		Carp::croak "No user passed to removeUser";
	}
	if (!$self->userExists($user)){
		$self->{infostr} = "User doesn't exist ($user) ";
		return 2;
	}
	my $query = "delete from $self->{tables}->{mailbox} where $self->{fields}->{mailbox}->{username} = '$user'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();
	$self->{infostr} = $query;
	if ($self->userExists($user)){
		$self->{errstr} = "Everything appeared successful but user $user still exists";
		return;
	}else{
		return 1;
	}
}	
	

=head3 removeDomain()

Removes the passed domain, and all of its attached users (using C<removeUser()> on each).  

Returns 1 on successful removal of a user, 2 if the user didn't exist to start with.

=cut

sub removeDomain(){
	my $self = shift;
	my $domain = shift;
	Carp::croak "No domain passed to removeDomain" if $domain eq '';
	
	unless ($self->domainExists($domain) >  0){
		$self->{errstr} = "Domain doesn't exist";
		return 2;
	}
	my @users = $self->getUsers($domain);
	foreach my $user (@users){
		$self->removeUser($user);
	}
	if($self->domainIsAlias($domain)){
		$self->removeAliasDomain($domain);
	}
	my $query = "delete from $self->{tables}->{domain} where $self->{fields}->{domain}->{domain} = '$domain'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	if ($self->domainExists($domain)){
		$self->{errstr} = "Everything appeared successful but domain $domain still exists";
		$self->{infostr} = $query;
		return;
	}else{
		$self->{infostr} = $query;
		return 2;
	}

}

=head3 removeAliasDomain()

Removes the alias property of a domain. An alias domain is just a normal domain which happens to be listed 
in a table matching it with a target. This simply removes that row out of that table; you probably want 
C<removeDomain>.

=cut

sub removeAliasDomain{
	my $self = shift;
	my $domain = shift;
	if ($domain eq ''){
		Carp::croak "No domain passed to removeAliasDomain";
	}
	if ( !$self->domainIsAlias($domain) ){
		$self->{infostr} = "Domain is not an alias ($domain)";
		return 3;
	}
	my $query = "delete from $self->{tables}->{alias_domain} where $self->{fields}->{alias_domain}->{alias_domain} = '$domain'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
}

=head3 removeAliasUser()

Removes the alias property of a user. An alias user is just a normal user which happens to be listed 
in a table matching it with a target. This simply removes that row out of that table; you probably want 
C<removeUser>.

=cut
sub removeAliasUser{
	my $self = shift;
	my $user = shift;
	if ($user eq ''){
		Carp::croak "No user passed to removeAliasUser";
	}
	if (!$self->userIsAlias){
		$self->{infoStr} = "user is not an alias ($user)";
		return 3;
	}
	my $query = "delete from $self->{tables}->{alias} where $self->{fields}->{alias}->{address} = '$user'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	return 1;
}
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
 # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
sub version{
	my $self = shift;
	return $VERSION
}
# dbConnection
# Deduces db details, returns an array of arguments to a 
# $dbi->connect()
sub _parsePostfixConfigFile{
	my $confFile = shift;
	my $maincf = shift;
	my $somefile;
	open(my $conf, "<", $confFile) or die ("Error opening postfix config file at $confFile : $!");
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
	my @dbiString = ("DBI:mysql:$db{'name'}:host=$db{'host'}", "$db{'user'}", "$db{'pass'}");
	return @dbiString;
}
sub _parseMysqlConfigFile{
	local $/ = "\n";
	my $confFile = shift;
	open(my $f, "<", $confFile) or die ("Error opening MySQL config file ($confFile) : $!");
	my ($user, $password, $host, $port, %db);
	foreach(<$f>){
		chomp $_;
		my ($k,$v) = split(/\s*=\s*/, $_);
		given($k){
			when(/^user/){$db{user}=$v;}
			when(/^password/){$db{pass}=$v;}
			when(/^host/){$db{host}=$v;}
			##TODO: find out how you're supposed to do this in a mysql.cnf:
			when(/^database/){$db{name}=$v;}
		}
	}

	my @dbiString = ("DBI:mysql:$db{'name'}:host=$db{'host'}:$db{'port'}", "$db{'user'}", "$db{'pass'}");
	return @dbiString;
}


=head2 Utilities

=head3 getOptions

Returns a hash of the options passed to the constructor plus whatever defaults 
were set, in the form that the constructor expects.

=cut

sub getOptions{
	my $self = shift;
	my %params = %{$self->{_params}};
	foreach(keys(%params)){
		print("$_\t=> $params{$_}\n");
	}
}
=head3 getTables getFields setTables setFields

C<get>ters return a hash defining the table and field names respectively, the
C<set>ters accept hashes in the same format for redefining the table layout.

Note that this is a representation of what the object assumes the db to be - 
there's no guessing at all as to what shape the db is so you'll need to tell
the object through these if you want to change them.

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


=head3 getdbCredentials()

Returns a hash of the db Credentials as expected by the constructor. Keys are 
C<dbi> C<dbuser> and C<dbpass>. These are the three arguments for the DBI 
constructor; C<dbi> is the full connection string (including C<DBI:mysql> at 
the beginning.

=cut

sub getdbCredentials{
	my $self = shift;
	my %return;
	foreach(qw/dbi dbuser dbpass/){
		$return{$_} = $self->{_params}{$_};
	}
	return %return;
}

=cut

sub dbCanStoreCleartextPasswords(){
	my $self = shift;
	my @fields = $self->{dbi}->selectrow_array("show columns from $self->{tables}->{mailbox}");
	if (grep(/($self->{fields}->{mailbox}->{password_cleartext})/, @fields)){
		return $1;
	}else{
		return
	}
}

=head3 now()

Returns the current time in a format suitable for passing straight to the database. Currently is just in MySQL 
datetime format (YYYY-MM-DD HH-MM-SS).

=cut

sub now{
	return _mysqlNow();
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
				'goto'		=> 'goto',	# Really should have been called 'target'
				'domain'	=> 'domain',
				'created'	=> 'created',
				'modified'	=> 'modified',
				'active'	=> 'active'

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
				'active'	=> 'active',
				'password_clear'=> 'password_clear',
				'password_gpg'  => 'password_gpg',
	};
	$fields{'domain_admins'} = {
	                        'domain'        => 'domain',
	                        'username'      => 'username'
	};
	$fields{'alias_domain'} = {
				'alias_domain'	=> 'alias_domain',
				'target_domain' => 'target_domain',
				'created'	=> 'created',
				'modified'	=> 'modified',
				'active'	=> 'active'
	};
	return %fields;
}


	
# Hopefully, a generic sub to pawn all db lookups off onto
#  _dbSelect(
#       table     => 'table',
#       fields    => [ field1, field2, field2],
#	equals	  => ["field", "What it equals"],
#	like      => ["field", "what it's like"],
#       orderby   => 'field4 desc'
#	count     => something
#  }
# If count *exists*, a count is returned. If not, it isn't.
# Returns an array of hashes, each hash representing a row from
# the db with keys as field names.
sub _dbSelect {
	my $self = shift;
	my %opts = @_;
	my $table = $opts{'table'};
	my @return;
	my @fields;

	if(exists($self->{'tables'}->{$table})){
		$table = $self->{'tables'}->{$table};
	}else{
		Carp::croak "Table '$table' not defined in %_tables";
	}

	foreach my $field (@{$opts{'fields'}}){
		unless(exists($self->{fields}->{$table}->{$field})){
			Carp::croak "Field $self->{fields}->{$table}->{$field} in table $table not defined in %_fields";
		}
		push (@fields, $self->{fields}->{$table}->{$field});
	}

	my $query = "select ";
	if (exists($opts{count})){
		$query .= "count(*) ";
	}else{
		$query .= join(", ", @fields);
	}
	$query .= " from $table ";
	if ($opts{'equals'} > 0){
		my ($field,$value) = @{$opts{'equals'}};
		if (exists($self->{fields}->{$table}->{$field})){
			$field = $self->{fields}->{$table}->{$field};
		}else{
			Carp::croak "Field $field in table $table (used in SQL conditional) not defined";
		}
		$query .= " where $field = '$value' ";
	}elsif ($opts{'like'} > 0){
		my ($field,$value) = @{$opts{'like'}};
		if (exists($self->{fields}->{$table}->{$field})){
			$field = $self->{fields}->{$table}->{$field};
		}else{
			Carp::croak "Field $field in table $table (used in SQL conditional) not defined";
		}
		$field = $self->{fields}->{$table}->{$field};
		$query .= " where $field like '$value'";
	}
	my $dbi = $self->{'dbi'};
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute() or Carp::croak "execute failed: $!";
	while(my $row = $sth->fetchrow_hashref){
		push(@return, $row);
	}
	return @return;
}

# Returns a timestamp of its time of execution in a format ready for inserting into MySQL
# (YYYY-MM-DD hh:mm:ss)
sub _mysqlNow() {
	
	my ($y,$m,$d,$hr,$mi,$se)=(localtime(time))[5,4,3,2,1,0];
	my $date = $y + 1900 ."-".sprintf("%02d",$m)."-$d";
	my $time = "$hr:$mi:$se";
	return "$date $time";
}

sub generatePassword() {
	my $self = shift;
	my $length = shift;
	my @characters = qw/a b c d e f g h i j k l m n o p q r s t u v w x y z
			    A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 
			    1 2 3 4 5 6 7 8 9 0 - =
			    ! " $ % ^ & * ( ) _ +
			    [ ] ; # , . : @ ~ < > ?
			  /;
	my $password;
	for( my $i = 0; $i<$length; $i++ ){
		$password .= $characters[rand($#characters)];
	}
	return $password;
}

# Check whether a field exists in the db. Must exist in the _field hash.
sub _fieldExists() {
	my ($dbi,$dbName,$tableName,$fieldName) = @_;
	my $query = "select count(*) from information_schema.COLUMNS where ";
	   $query.= "TABLE_SCHEMA='$dbName' and TABLE_NAME='$tableName' and ";
	   $query.= "COLUMN_NAME='$fieldName'";
	my $sth = $dbi->prepare($query);
	$sth->execute;
	my $count = ($sth->fetchrow_array())[0];
	return($count) if ($count > 0);
	return;
}

=head1 CLASS VARIABLES

=cut

#=head3 errstr
#
#C<$p->errstr> contains the error message of the last action. If it's empty (i.e. C<$v->errstr eq ''>) then it should be safe to assume
#nothing went wrong. Currently, it's only used where the creation or deletion of something appeared to succeed, but the something 
#didn't begin to exist or cease to exist.
#
#=head3 infostr
#
#C<$v->infostr> is more useful.
#Generally, it contains the SQL queries used to perform whatever job the function performed, excluding any ancilliary checks. If it
#took more than one SQL query, they're concatenated with semi-colons between them.
#
#It also populated when trying to create something that exists, or delete something that doesn't.

=head3 dbi

C<dbi> is the dbi object used by the rest of the module, having guessed/set the appropriate credentials. 
You can use it as you would the return directly from a $dbi->connect:

  my $sth = $p->{dbi}->prepare($query);
  $sth->execute;

=head3 params

C<params> is the hash passed to the constructor, including any interpreting it does. If you've chosen to authenticate by passing
the path to a main.cf file, for example, you can use the database credentials keys (C<dbuser, dbpass and dbi>) to initiate your 
own connection to the db (though you may as well use dbi, above). 

Other variables are likely to be put here as I decide I'd like to use them :)

=head1 DIAGNOSTICS

Functions generally return:

=over

=item * null on failure

=item * 1 on success

=item * 2 where there was nothing to do (as if their job had already been performed)

=back

See C<errstr> and C<infostr> for better diagnostics.

=head2 The DB schema

Internally, the db schema is stored in two hashes. 

C<%_tables> is a hash storing the names of the tables. The keys are the values used internally to refer to the 
tables, and the values are the names of the tables in the db.

C<%_fields> is a hash of hashes. The 'top' hash has as keys the internal names for the tables (as found in 
C<getTables()>), with the values being hashes representing the tables. Here, the key is the name as used internally, 
and the value the names of those fields in the SQL.

Currently, the assumptions made of the database schema are very small. We asssume four tables, 'mailbox', 'domain', 
'alias' and 'alias domain':

 mysql> describe mailbox;
 +------------+--------------+------+-----+---------------------+-------+
 | Field      | Type         | Null | Key | Default             | Extra |
 +------------+--------------+------+-----+---------------------+-------+
 | username   | varchar(255) | NO   | PRI | NULL                |       |
 | password   | varchar(255) | NO   |     | NULL                |       |
 | name       | varchar(255) | NO   |     | NULL                |       |
 | maildir    | varchar(255) | NO   |     | NULL                |       |
 | quota      | bigint(20)   | NO   |     | 0                   |       |
 | local_part | varchar(255) | NO   |     | NULL                |       |
 | domain     | varchar(255) | NO   | MUL | NULL                |       |
 | created    | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | modified   | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | active     | tinyint(1)   | NO   |     | 1                   |       |
 +------------+--------------+------+-----+---------------------+-------+
 10 rows in set (0.00 sec)
   
 mysql> describe domain;
 +-------------+--------------+------+-----+---------------------+-------+
 | Field       | Type         | Null | Key | Default             | Extra |
 +-------------+--------------+------+-----+---------------------+-------+
 | domain      | varchar(255) | NO   | PRI | NULL                |       |
 | description | varchar(255) | NO   |     | NULL                |       |
 | aliases     | int(10)      | NO   |     | 0                   |       |
 | mailboxes   | int(10)      | NO   |     | 0                   |       |
 | maxquota    | bigint(20)   | NO   |     | 0                   |       |
 | quota       | bigint(20)   | NO   |     | 0                   |       |
 | transport   | varchar(255) | NO   |     | NULL                |       |
 | backupmx    | tinyint(1)   | NO   |     | 0                   |       |
 | created     | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | modified    | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | active      | tinyint(1)   | NO   |     | 1                   |       |
 +-------------+--------------+------+-----+---------------------+-------+
 11 rows in set (0.00 sec)

 mysql> describe alias_domain;
 +---------------+--------------+------+-----+---------------------+-------+
 | Field         | Type         | Null | Key | Default             | Extra |
 +---------------+--------------+------+-----+---------------------+-------+
 | alias_domain  | varchar(255) | NO   | PRI | NULL                |       |
 | target_domain | varchar(255) | NO   | MUL | NULL                |       |
 | created       | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | modified      | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | active        | tinyint(1)   | NO   | MUL | 1                   |       |
 +---------------+--------------+------+-----+---------------------+-------+
 5 rows in set (0.00 sec)

 mysql> describe alias;
 +----------+--------------+------+-----+---------------------+-------+
 | Field    | Type         | Null | Key | Default             | Extra |
 +----------+--------------+------+-----+---------------------+-------+
 | address  | varchar(255) | NO   | PRI | NULL                |       |
 | goto     | text         | NO   |     | NULL                |       |
 | domain   | varchar(255) | NO   | MUL | NULL                |       |
 | created  | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | modified | datetime     | NO   |     | 0000-00-00 00:00:00 |       |
 | active   | tinyint(1)   | NO   |     | 1                   |       |
 +----------+--------------+------+-----+---------------------+-------+
 6 rows in set (0.00 sec)

And, er, that's it. If you wish to store cleartext passwords (by passing a value greater than 0 for 'storeCleartextPassword'
to the constructor) you'll need a 'password_cleartext' column on the mailbox field. 

C<getFields> returns C<%_fields>, C<getTables %_tables>. C<setFields> and C<setTables> resets them to the hash passed as an 
argument. It does not merge the two hashes.

This is the only way you should be interfering with those hashes.

Since the module does no guesswork as to the db schema (yet), you might need to use these to get it to load 
yours. Even when it does do that, it might guess wrongly.



=head1 REQUIRES

=over 

=item * Perl 5.10

=item * Crypt::PasswdMD5 

=item * Carp

=item * DBI

=back

Crypt::PasswdMD5 is C<libcyrpt-passwdmd5-perl> in Debian, 
DBI is C<libdbi-perl>

=cut

1
