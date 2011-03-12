vpostmail
=========

Vpostmail is an attempt to provide the same command line tools as provided in
Vpopmail, but for a Postfix/Dovecot/MySQL environment. Alternatively, it's an
attempt to provide a command-line version of postfixadmin. It expects the
Postfixadmin design of the db schema, but this is configurable.

It is to be implemented as a single file whose behaviour changes depending upon
which name it was called by, in order to keep it as a single easily-portable
file.

Most importantly, this doesn't work at all yet :)

