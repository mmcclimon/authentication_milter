package Mail::Milter::Authentication::Handler::Generic;

use strict;
use warnings;

our $VERSION = 0.4;

use base 'Mail::Milter::Authentication::Protocol';

use Mail::Milter::Authentication::Config qw{ get_config };

use Email::Address;
use Sys::Syslog qw{:standard :macros};

sub new {
    my ( $class, $ctx ) = @_;
    my $self = {
        'ctx'    => $ctx,
        'config' => get_config(),
    };
    bless $self, $class;
    return $self;
}

sub config {
    my ($self) = @_;
    return $self->{'config'};
}

sub get_top_handler {
    my ($self) = @_;
    my $ctx    = $self->{'ctx'};
    my $priv   = $ctx->getpriv();
    my $object = $priv->{'handler_object'};

    #weaken $object;
    return $object;

}

sub get_handler {
    my ( $self, $handler ) = @_;
    my $top_handler = $self->get_top_handler();
    my $object      = $top_handler->{'handler'}->{$handler};
    return $object;
}

sub set_handler {
    my ( $self, $handler, $object ) = @_;
    my $top_handler = $self->get_top_handler();
    $top_handler->{'handler'}->{$handler} = $object;
}

sub destroy_handler {
    my ( $self, $handler ) = @_;
    my $top_handler = $self->get_top_handler();
    delete $top_handler->{'handler'}->{$handler};
}

sub is_local_ip_address {
    my ($self) = @_;
    my $local_handler = $self->get_handler('localip');
    return $local_handler->{'is_local_ip_address'};
}

sub is_trusted_ip_address {
    my ($self) = @_;
    my $trusted_handler = $self->get_handler('trustedip');
    return $trusted_handler->{'is_trusted_ip_address'};
}

sub is_authenticated {
    my ($self) = @_;
    my $auth_handler = $self->get_handler('auth');
    return $auth_handler->{'is_authenticated'};
}

sub ip_address {
    my ($self) = @_;
    my $core_handler = $self->get_handler('core');
    return $core_handler->{'ip_address'};
}

sub helo_name {
    my ($self) = @_;
    my $core_handler = $self->get_handler('core');
    return $core_handler->{'helo_name'};
}

sub mail_from {
    my ($self) = @_;
    my $core_handler = $self->get_handler('core');
    return $core_handler->{'mail_from'};
}

sub format_ctext {

    # Return ctext (but with spaces intact)
    my ( $self, $text ) = @_;
    $text =~ s/\t/ /g;
    $text =~ s/\n/ /g;
    $text =~ s/\r/ /g;
    $text =~ s/\(/ /g;
    $text =~ s/\)/ /g;
    $text =~ s/\\/ /g;
    return $text;
}

sub format_ctext_no_space {
    my ( $self, $text ) = @_;
    $text = $self->format_ctext($text);
    $text =~ s/ //g;
    return $text;
}

sub format_header_comment {
    my ( $self, $comment ) = @_;
    $comment = $self->format_ctext($comment);
    return $comment;
}

sub format_header_entry {
    my ( $self, $key, $value ) = @_;
    $key   = $self->format_ctext_no_space($key);
    $value = $self->format_ctext_no_space($value);
    my $string = $key . '=' . $value;
    return $string;
}

sub get_domain_from {
    my ( $self, $address ) = @_;
    $address = $self->get_address_from($address);
    my $domain = 'localhost.localdomain';
    $address =~ s/<//g;
    $address =~ s/>//g;
    if ( $address =~ /\@/ ) {
        ($domain) = $address =~ /.*\@(.*)/;
    }
    return lc $domain;
}

sub get_address_from {
    my ( $self, $address ) = @_;
    my @addresses = Email::Address->parse($address);
    if (@addresses) {
        my $first = $addresses[0];
        return $first->address();
    }
    else {
        # We couldn't parse, so just run with it and hope for the best
        return $address;
    }
}

sub get_my_hostname {
    my ($self) = @_;
    return $self->get_symval('j');
}

sub is_hostname_mine {
    my ( $self, $check_hostname ) = @_;
    my $CONFIG = $self->config();

    my $hostname = $self->get_my_hostname();
    my ($check_for) = $hostname =~ /^[^\.]+\.(.*)/;

    if ( exists( $CONFIG->{'hosts_to_remove'} ) ) {
        foreach my $remove_hostname ( @{ $CONFIG->{'hosts_to_remove'} } ) {
            if (
                substr( lc $check_hostname, ( 0 - length($remove_hostname) ) ) eq
                lc $remove_hostname )
            {
                return 1;
            }
        }
    }

    if (
        substr( lc $check_hostname, ( 0 - length($check_for) ) ) eq
        lc $check_for )
    {
        return 1;
    }
}

sub dbgout {
    my ( $self, $key, $value, $priority ) = @_;
    warn "$key: $value\n";
    my $core_handler = $self->get_handler('core');
    if ( !exists( $core_handler->{'dbgout'} ) ) {
        $core_handler->{'dbgout'} = [];
    }
    push @{ $core_handler->{'dbgout'} },
      {
        'priority' => $priority || LOG_INFO,
        'key'      => $key      || q{},
        'value'    => $value    || q{},
      };
}

sub log_error {
    my ( $self, $error ) = @_;
    $self->dbgout( 'ERROR', $error, LOG_ERR );
}

sub dbgoutwrite {
    my ($self) = @_;
    eval {
        openlog('authentication_milter', 'pid', LOG_MAIL);
        setlogmask(   LOG_MASK(LOG_ERR)
                    | LOG_MASK(LOG_INFO)
#                    | LOG_MASK(LOG_DEBUG)
        );
        my $queue_id = $self->get_symval('i') || q{--};
        my $core_handler = $self->get_handler('core');
        if ( exists( $core_handler->{'dbgout'} ) ) {
            foreach my $entry ( @{ $core_handler->{'dbgout'} } ) {
                my $key      = $entry->{'key'};
                my $value    = $entry->{'value'};
                my $priority = $entry->{'priority'};
                my $line     = "$queue_id: $key: $value";
                syslog( $priority, $line );
            }
        }
        closelog();
        delete $core_handler->{'dbgout'};
    };
}

sub add_headers {
    my ($self) = @_;

    my $header = $self->get_my_hostname();
    my @auth_headers;
    my $core_handler = $self->get_handler('core');
    if ( exists( $core_handler->{'c_auth_headers'} ) ) {
        @auth_headers = @{ $core_handler->{'c_auth_headers'} };
    }
    if ( exists( $core_handler->{'auth_headers'} ) ) {
        @auth_headers = ( @auth_headers, @{ $core_handler->{'auth_headers'} } );
    }
    if (@auth_headers) {
        $header .= ";\n    ";
        $header .= join( ";\n    ", sort @auth_headers );
    }
    else {
        $header .= '; none';
    }

    $self->prepend_header( 'Authentication-Results', $header );

    if ( exists( $core_handler->{'pre_headers'} ) ) {
        foreach my $header ( @{ $core_handler->{'pre_headers'} } ) {
            $self->dbgout( 'PreHeader',
                $header->{'field'} . ': ' . $header->{'value'}, LOG_INFO );
            $self->insert_header( 1, $header->{'field'}, $header->{'value'} );
        }
    }

    if ( exists( $core_handler->{'add_headers'} ) ) {
        foreach my $header ( @{ $core_handler->{'add_headers'} } ) {
            $self->dbgout( 'AddHeader',
                $header->{'field'} . ': ' . $header->{'value'}, LOG_INFO );
            $self->addheader( $header->{'field'}, $header->{'value'} );
        }
    }
}

sub prepend_header {
    my ( $self, $field, $value ) = @_;
    my $core_handler = $self->get_handler('core');
    if ( !exists( $core_handler->{'pre_headers'} ) ) {
        $core_handler->{'pre_headers'} = [];
    }
    push @{ $core_handler->{'pre_headers'} },
      {
        'field' => $field,
        'value' => $value,
      };
}

sub add_auth_header {
    my ( $self, $value ) = @_;
    my $core_handler = $self->get_handler('core');
    if ( !exists( $core_handler->{'auth_headers'} ) ) {
        $core_handler->{'auth_headers'} = [];
    }
    push @{ $core_handler->{'auth_headers'} }, $value;
}

sub add_c_auth_header {

    # Connection wide auth headers
    my ( $self, $value ) = @_;
    my $core_handler = $self->get_handler('core');
    if ( !exists( $core_handler->{'x_auth_headers'} ) ) {
        $core_handler->{'c_auth_headers'} = [];
    }
    push @{ $core_handler->{'c_auth_headers'} }, $value;
}

sub append_header {
    my ( $self, $field, $value ) = @_;
    my $core_handler = $self->get_handler('core');
    if ( !exists( $core_handler->{'add_headers'} ) ) {
        $core_handler->{'add_headers'} = [];
    }
    push @{ $core_handler->{'add_headers'} },
      {
        'field' => $field,
        'value' => $value,
      };
}

1;
