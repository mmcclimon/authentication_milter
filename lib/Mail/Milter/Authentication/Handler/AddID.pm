package Mail::Milter::Authentication::Handler::AddID;
use strict;
use warnings;
use base 'Mail::Milter::Authentication::Handler';
# VERSION

use Sys::Syslog qw{:standard :macros};

sub default_config {
    return {};
}

sub eom_callback {

    # On HELO
    my ( $self, $helo_host ) = @_;
    $self->append_header('X-Authentication-Milter','Header added by Authentication Milter');
    return;
}

1;

__END__

=head1 DESCRIPTION

Simple module which adds a header to all email processed.

This is meant as an example only.

=head1 CONFIGURATION

No configuration options exist for this handler.

