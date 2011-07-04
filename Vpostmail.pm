#! /usr/bin/perl

use strict;
use 5.010;
use DBI;
use Crypt::PasswdMD5;	# libcrypt-passwdmd5-perl
use Carp;

##Todo: detect & support different password hashes

=pod

=head1 NAME

Vpostmail - Interferes with a Postfix/Dovecot/MySQL system

=head1 SYNOPSIS

	use Vpostmail;

	my $v = Vpostmail->new();
	$v->setDomain("example.org");
	$v->createDomain(
		description => 'an example',
		num_mailboxes => '0'
	);

	$v->setUser("foo@example.org");
	$v->createUser(
		password_plain => 'password',
		name => 'alice'
	);

	my %dominfo = $v->getDomainInfo();

	my %userinfo = $v->getUserInfo();

	$v->changePassword('complexpass');

=head1 REQUIRES

=over 

=item * Perl 5.10

=item * Crypt::PasswdMD5 

=item * Carp

=item * DBI

=back

Crypt::PasswdMD5 is C<libcyrpt-passwdmd5-perl> in Debian, 
DBI is C<libdbi-perl>


=head1 DESCRIPTION

Vpostmail is an attempt to provide a bunch of neat functions that wrap around the tedious SQL involved
in interfering with a Postfix/Dovecot/MySQL virtual mailbox mail system. It can probably be used on others
so long as the DB schema is similar enough.

It's _very_much_ still in development. All sorts of things will change :) This is currently a todo list as much
as it is documentation of the module.

=cut

package Vpostmail;
sub new() {
	my $class = shift;
	my $self = {};
	bless($self,$class);
	$self->{dbCredentials};
	$self->{configFiles}->{'postfix'} = '/etc/postfix/main.cf';
	$self->{dbi} = &_dbConnection('/etc/postfix/main.cf');
	$self->{errstr};
	$self->{infostr};
	my %_tables = &_tables;
	$self->{tables} = \%_tables;
	my %_fields = &_fields;
	$self->{fields} = \%_fields;
	return $self;
}

=head1 METHODS

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

=head2 Getters and Setters

Anything that operates on a domain or a user will expect the object's user or domain to have already been set with 
one of these. The getters and setters are

 getUser()
 getDomain()
 setUser()
 setDomain()

Functions do not, in general, expect to be passed either a user or a domain as an argument, with C<createDomain()> and 
C<createUser()> acting as notable examples - they will accept either set in the hash of settings they're passed.

There is also a pair of 'unsetters':

 unsetUser()
 unsetDomain()

The setters will return the value to which they have set the variable; these two are equivalent:

  $d->setDomain('example.org');
  print $d->getDomain();

  print $d->setDomain('example.org');

in that both will print 'example.org'. 

=over 4

=item setUser()

setUser may either be passed the full username (C<bob@example.org>) or, if a domain is already set with C<setDomain()>, just
the left-hand-side (C<bob>). These two are equivalent:

 $d->setDomain('example.org');
 $d->setUser('bob');

 $d->setUser('bob@example.org');

Note that this behaviour depends upon the argument to C<setUser()>, not only the set-ness of a domain. If no domain is 
set, then the argument to C<setUser> is always assumed to be the whole username.

If a domain is set, then the argument is assumed to be a whole email address if it contains a '@', else it's assumed
to be a left-hand-side only.

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

Sets the domain or the user to C<undef>. Returns the previous value of the variable, rather than the new value (which you 
would get out of the setters):

  $d->setDomain('example.org')
  print $d->setDomain(undef);

will print undef, whereas

  $d->setDomain('example.org)
  print $d->unsetDomain();

will print 'C<example.org>'

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

=back

=head2 User and domain information

=over

=item numDomains()

Returns the number of domains configured on the server. If you'd like only those that match some pattern, you should use C<listDomains()> and measure 
the size of the returned list.

=cut


sub numDomains(){
	my $self = shift;
	my $query = "select count(*) from $self->{tables}->{domain}";
	my $numDomains = ($self->{dbi}->selectrow_array($query))[0];
	$numDomains--;	# since there's an 'ALL' domain in the db
	$self->{_numDomains} = $numDomains;
	$self->{infostr} = $query;
	return $self->{_numDomains};
}


=item numUsers()

Returns the number of configured users. If a domain is set (with C<setDomain()>) it will only return users configured on that domain. If not, 
it will return all the users. If you'd like only those that match some pattern, you should use C<listUsers()> and measure the size of the returned
list.

=cut

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
	$self->{infostr} = $query;
	return $numUsers;
}

=item listDomains() 

Returns a list of domains on the system. You may pass a regex as an argument, and only those domains matching that regex are supplied. There's 
no way of passing options, and the regex is matched case-sensitively - you need to build insensitivity in to the pattern if you want it.

=cut

sub listDomains(){
	my $self = shift;
	my $regex = shift;
	my $regexOpts = shift;
	my $query;
	my $query = "select domain from $self->{tables}->{domain}";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my @domains;
	while(my @row = $sth->fetchrow_array()){
		if ($row[0] =~ /$regex/){
			push(@domains, $row[0]) unless $row[0] =~ /^ALL$/;
		}
	}
	$self->{infostr} = $query;
	return @domains;
}


=item listDomains() 

Returns a list of users on the system (or, if it's previously been defined, the domain). 

You may pass a regex as an argument, and only those users matching that regex are supplied. There's no way of passing options, and the regex is 
matched case-sensitively - you need to build insensitivity in to the pattern if you want it.

=cut

sub listUsers(){
	my $self = shift;
	my $regex = shift;
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
		if($row[0] =~ /$regex/){
			push(@users, $row[0]);
		}
	}
	$self->{infostr} = $query;
	return @users;
}

=item domainExists() and userExists()

Check for the existence of a user or a domain. Returns the amount it found (in anticipation of also serving as a sort-of search)
if the domain or user does exist, empty otherwise.

=cut

sub domainExists(){
	my $self = shift;
	my $domain;
	$domain = $self->{_domain};
	if ($domain eq ''){
		Carp::croak "No domain set";
	}
	if($self->domainIsAlias){
		return $?;
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

sub userExists(){
	my $self = shift;
	my $user = $self->{_user};
	if ($user eq ''){
		Carp::croak "No user set";
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

sub domainIsAlias(){
	my $self = shift;
	my $domain = $self->{_domain};
	if ($domain eq ''){
		Carp::croak "No domain set";
	}
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

sub domainIsTarget(){
	my $self = shift;
	my $domain = $self->{_domain};
	if ($domain eq ''){
		Carp::croak "No domain set";
	}
	my $query = "select count(*) from $self->{tables}->{alias_domain} where $self->{fields}->{alias_domain}->{target_domain} = '$domain'";
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
=item getUserInfo()

Returns a hash containing info about the user. The keys are the same as the internally-used names for the fields
in the SQL (as you can find from C<getFields()> and C<getTables()> ).

The hash keys are essentially the same as those found by getFields:

	username	The username. Hopefully redundant.
	password	The crypted password of the user
	name		The human name associated with the username
	domain		The domain the user is associated with
	local_part	The local part of the email address
	maildir		The path to the maildir *relative to the maildir root configured in Postfix/Dovecot*
	active		Whether or not the user is active
	created		Creation data
	modified	Last modified data


User needs to have been set previously.

The hash is returned even in the eventuality that it is empty. This function does not test for the existence of
a user, (use C<userExists()> for that).

=cut

sub getUserInfo(){
	my $self = shift;
	my $user;
	$user = $self->{_user};
	if ($user eq ''){
		Carp::croak "No user set";
	}
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
	$self->{infostr} = $query;
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
	aliases		Alias quota for the domain
	maxquota	Mailbox quota for teh domain


Domain needs to have been set previously.

The hash is returned even if it is empty - this does not check for the existence of a domain, that's what I gave you C<domainExists()> for.

=cut

sub getDomainInfo(){
	my $self = shift;
	my $domain = $self->{_domain};
	my $query = "select * from `$self->{tables}->{domain}` where $self->{fields}->{domain}->{domain} = '$domain'";

	if ($domain eq ''){
		Carp::croak "No domain set";
	}

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


sub getTargetAliases{
	my $self = shift;
	my $domain = $self->{_domain};
	if ($domain eq ''){ Carp::croak "No domain set"; }
	my $query = "select $self->{fields}->{alias_domain}->{alias_domain} from $self->{tables}->{alias_domain} where $self->{fields}->{alias_domain}->{target_domain} = '$domain'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	my @aliases;
	while(my @row = $sth->fetchrow_array){
		push(@aliases, $row[0]);
	}
	if ($#aliases > 0){
		return @aliases;
	}else{
		return;
	}
}

=back

=head2 Passwords

=over 

=item cryptPassword()

This probably has no real use, except for where other functions use it. It should let you specify a 
salt for the password, but doesn't yet. It expects a cleartext password as an argument, and returns the crypted sort. 

=cut

sub cryptPassword(){
	my $self = shift;
	my $password = shift;
	my $cryptedPassword = Crypt::PasswdMD5::unix_md5_crypt($password);
	return $cryptedPassword;
}

=item changePassword() 

Changes the password of a user. The user should be set with C<setUser> (or equivalent) and the cleartext password 
passed as an argument. It returns the encrypted password as written to the DB. 
The salt is picked at pseudo-random; successive runs will (should) produce different results.

=cut

sub changePassword(){
	my $self = shift;
	my $user = $self->{_user};
	my $password = shift;
	if ($user eq ''){
		Carp::croak "No user set";
	}
	
	my $cryptedPassword = $self->cryptPassword($password);

	my $query = "update `$self->{tables}->{mailbox}` set `$self->{fields}->{mailbox}->{password}`=? where `$self->{fields}->{mailbox}->{username}`='$user'";
	$self->{infostr} = $query;
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute($cryptedPassword);
	return $cryptedPassword;
}

=item changeCryptedPassword()

changeCryptedPassword operates in exactly the same way as changePassword, but it expects to be passed an already-encrypted 
password, rather than a clear text one. It does no processing at all of its arguments, just writes it
into the database.

=cut

sub changeCryptedPassword(){
	my $self = shift;
	my $user = $self->{_user};

	if ($user eq ''){
		Carp::croak "No user set";
	}
	my $cryptedPassword = shift;

	my $query = "update `$self->{tables}->{mailbox}` set `$self->{fields}->{mailbox}->{password}`=? where `$self->{fields}->{mailbox}->{username}`='$user'";

	my $sth = $self->{dbi}->prepare($query);
	$sth->execute($cryptedPassword);

	$self->{infostr} = $query;
	return $cryptedPassword;
}

=back 

=head2 Creating things

=over

=item createDomain()

Expects to be passed a hash of options, with the keys being the same as those output by C<getDomainInfo()>. None
are necessary (provided C<setDomain()> has been called so it knows which domain it's creating). If the 'domain' 
key is in the hash passed, this overrules the set domain.

Defaults are set as follows:

	domain		The domain as set with setDomain. Errors without this
	description	A null string
	quota		MySQL's default
	transport	'virtual'
	active		1 (active)
	backupmx0	MySQL's default
	modified	now
	created		now
	aliases		MySQL's default
	maxquota	MySQL's default

Defaults are only set on keys that haven't been instantiated. If you set a key to undef or a null string, it will
not be set to the default - null will be passed to the DB and it may set its own default.

On both success and failure the function will return a hash containing the options used to configure the domain - 
you can inspect this to see which defaults were set by the module if you like.

If the domain already exists, this function will not alter it. It wil exit with a return value of 2 (indicating that
it thinks its job has already been done) and populate the C<infostr> with "Domain already exists (<domain>)". In this 
instance, you don't get the hash.

=cut

sub createDomain(){
	my $self = shift;
	my %opts = @_;
	my $fields;
	my $values;
	$opts{domain} = $self->{_domain} unless exists($opts{domain});
	$self->{_domain} = $opts{domain};
	if($self->{_domain} eq ''){
		Carp::croak "No domain set";
	}

	if ($self->domainExists()){
		$self->{infostr} = "Domain already exists ($self->{_domain})";
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
	if($self->domainExists()){
		return %opts;
	}else{
		$self->{errstr} = "Everything appeared to succeed, but the domain doesn't exist";
		return;
	}
}

=item createUser()

Expects to be passed a hash of options, with the keys being the same as those output by C<etUserInfo()>. None
are necessary (provided a user has been set so it knows which user to create). If the 'username' key is in the
passed hash, it overrides any set user.

If both C<password_plain> and <password_crypt> are in the passed hash, C<password_crypt> will be used. If only 
password_plain is passed it will be crypted with C<cryptPasswd()> and then inserted.

Defaults are mostly sane where values aren't explicitly passed:


 password	null
 name		null
 maildir 	username with a '/' appended to it
 quota		MySQL default (normally zero)
 local_part	the part of the username to the left of the first '@'
 domain		the part of the username to the right of the last '@'
 created	now
 modified	now
 active		MySQL's default

These are only set if they fail an C<exists()> test; if C<undef> is passed, for example, it will not be clobbered 
- null will be written to MySQL and it will take care of any defaults.

On both success and failure, the function will return a hash containing the options used to configure the user - 
you can inspect this to see which defaults were set.

If the domain already exists, this function will not alter it. It wil exit with a return value of 2 (indicating that
it thinks its job has already been done) and populate C<infostr> with "User already exists (<user>)" In this 
instance, you don't get the hash.

=cut

sub createUser(){
	my $self = shift;
	my %opts = @_;
	my $fields;
	my $values;

	$opts{username} = $self->{_user} unless (exists $opts{username});
	$self->{_user} = $opts{username};
	if($self->{_user} eq ''){
		Carp::croak "No user set";
	}
	if($self->userExists()){
		$self->{infostr} = "User already exists ($self->{_user})";
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
		Carp::croak "No user set";
	}
	$values =~ s/, $//;
	$fields =~ s/, $//;
	my $query = "insert into `$self->{tables}->{mailbox}` ";
	$query.= " ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();	
	$self->{infostr} = $query;
	if($self->userExists()){
		return %opts;
	}else{
		$self->{errstr} = "Everything appeared to succeed, but the user doesn't exist";
		return;
	}
}

sub createAliasDomain {
	my $self = shift;
	my %opts = @_;
	if ($self->{_domain} eq ''){
		Carp::croak "No domain set";
	}
	unless(exists($opts{'target'})){
		Carp::croak "No target passed";
	}
	unless($self->domainExists){
		$self->createDomain;
	}
	my $fields = "$self->{fields}->{alias_domain}->{alias_domain}, $self->{fields}->{alias_domain}->{target_domain}";
	my $values = " '$self->{_domain}', '$opts{target}'";
	if(exists($opts{'created'})){
		$fields.=", $self->{fields}->{alias_domain}->{created}";
		$values=", '$opts{'created'}'";
	}
	if(exists($opts{'modified'})){
		$fields.=", $self->{fields}->{alias_domain}->{modified}";
		$values.=", $opts{'modified'}";
	}
	if(exists($opts{'active'})){
		$fields.=", $self->{fields}->{alias_domain}->{active}";
		$values.=", '$opts{'active'}'";
	}
	my $query = "insert into $self->{tables}->{alias_domain} ( $fields ) values ( $values )";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	if($self->domainExists()){
		$self->{infostr} = $query;
		return %opts;

	}else{
		$self->{infostr} = $query;
		$self->{errstr} = "Everything appeared to succeed but the domain doesn't exist";
		return;
	}
}

=back

=head2 Deleting things

=over

=item removeUser();

Removes the user set in C<setUser()>.

Returns 1 on successful removal of a user, 2 if the user didn't exist to start with.

C<infostr> is set to the query run only if the user exists. If the user doesn't exist, no query is run
and C<infostr> is set to "user doesn't exist (<user>)";

=cut

##Todo: Accept a hash of field=>MySQL regex with which to define users to delete
sub removeUser(){
	my $self = shift;
	my $username = $self->{_user};
	if($self->{_user} eq ''){
		Carp::croak "No user set";
	}
	if (!$self->userExists){
		$self->{infostr} = "User doesn't exist ($self->{_user}) ";
		return 2;
	}
	my $query = "delete from $self->{tables}->{mailbox} where $self->{fields}->{mailbox}->{username} = '$username'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute();
	$self->{infostr} = $query;
	if ($self->userExists()){
		$self->{errstr} = "Everything appeared successful but user $self->{_user} still exists";
		return;
	}else{
		return 1;
	}
}	
	

=item removeDomain()

Removes the domain set in C<SetDomain()>, and all of its attached users (using C<removeUser()>).  

Returns 1 on successful removal of a user, 2 if the user didn't exist to start with.

C<infostr> is set to the query run only if the domain exists - if the domain doesn't exist no query is run and C<infostr> is set to 
"domain doesn't exist (<domain>)";

=cut

sub removeDomain(){
	my $self = shift;
	my $domain = $self->{_domain};
	if ($domain eq ''){
		Carp::croak "No domain set";
	}
	if (!$self->domainExists){
		$self->{infostr} = "Domain doesn't exist ($self->{infostr})";
		return 2;
	}
	my @users = $self->listUsers();
	foreach(@users){
		$self->{_user} = $_;
		$self->removeUser();
	}
	$self->{user} = undef;
	my $query;
	my $query = "delete from $self->{tables}->{domain} where $self->{fields}->{domain}->{domain} = '$domain'";
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
	if ($self->domainExists()){
		$self->{errstr} = "Everything appeared successful but domain $self->{_domain} still exists";
		$self->{infostr} = $query;
		return;
	}else{
		$self->{infostr} = $query;
		return 2;
	}

}

sub removeAlias{
	my $self = shift;
	my $domain = $self->{_domain};
	if ($domain eq ''){
		Carp::croak "No domain set";
	}
	if (!$self->domainIsAlias){
		$self->{infostr} = "Domain is not an alias ($self->{_domain})";
		return 3;
	}
	my $query = "delete from $self->{tables}->{alias_domain} where $self->{fields}->{alias_domain}->{alias_domain} = '$domain'";
	print $query;
	my $sth = $self->{dbi}->prepare($query);
	$sth->execute;
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
        my $dbh = DBI->connect("DBI:mysql:$db{'name'}:host=$db{'host'}", $db{'user'}, $db{'pass'}, {RaiseError => '1'}) || die "Could not connect to database: $DBI::errstr";
        return $dbh
}

=back 

=head2 The DB schema

Internally, the db schema is stored in two hashes. 

C<%_tables> is a hash storing the names of the tables. The keys are the values used internally to refer to the 
tables, and the values are the names of the tables in the db.

C<%_fields> is a hash of hashes. The 'top' hash has as keys the internal names for the tables (as found in 
C<getTables()>), with the values being hashes representing the tables. Here, the key is the name as used internally, 
and the value the names of those fields in the SQL.

Currently, the assumptions made of the database schema are very small. We asssume two tables, 'mailbox' and 
'domain':

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

And, er, that's it.

C<getFields> returns C<%_fields>, C<getTables %_tables>. C<setFields> and C<setTables> resets them to the hash passed as an 
argument. It does not merge the two hashes.

This is the only way you should be interfering with those hashes.

Since the module does no guesswork as to the db schema (yet), you might need to use these to get it to load 
yours. Even when it does do that, it might guess wrongly.



=cut
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
	$fields{'alias_domain'} = {
				'alias_domain'	=> 'alias_domain',
				'target_domain' => 'target_domain',
				'created'	=> 'created',
				'modified'	=> 'modified',
				'active'	=> 'active'
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

=head1 CLASS VARIABLES

=over

=item errstr

C<$v->errstr> contains the error message of the last action. If it's empty (i.e. C<$v->errstr eq ''>) then it should be safe to assume
nothing went wrong. Currently, it's only used where the creation or deletion of something appeared to succeed, but the something 
didn't begin to exist or cease to exist.

=item infostr

C<$v->infostr> is more useful.
Generally, it contains the SQL queries used to perform whatever job the function performed, excluding any ancilliary checks. If it
took more than one SQL query, they're concatenated with semi-colons between them.

It also populated when trying to create something that exists, or delete something that doesn't.

=item dbi

C<$v->dbi> is the dbi object used by the rest of the module, having guessed/set the appropriate credentials.

=back

=head1 DIAGNOSTICS

Functions generally return:

=over

=item * null on failure

=item * 1 on success

=item * 2 where there was nothing to do (as if their job had already been performed)

=back

See C<errstr> and C<infostr> for better diagnostics.

=cut

1
