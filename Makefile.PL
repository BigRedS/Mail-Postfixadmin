use 5.010001;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
	NAME              => 'Mail::Vpostmail',
	VERSION_FROM      => 'lib/Mail/Vpostmail.pm', # finds $VERSION
	PREREQ_PM         => {
		'DBI'			=> '1.612',
		'Crypt::PasswdMD5'	=> '1.3'
	},
	EXE_FILES	=> [qw(bin/vaddaliasuser bin/vuserinfo bin/vpasswd bin/vdominfo bin/vdeluser bin/vadduser bin/vdeldomain bin/vadddomain bin/vaddaliasdomain)],
        ($] >= 5.005 ? (
		ABSTRACT_FROM  => 'lib/Mail/Postfixadmin.pm',
		AUTHOR         => 'Avi Greenbury <mail-postfixadmin@code.avi.co>') : ()
	),
);
