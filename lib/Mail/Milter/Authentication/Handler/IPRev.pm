package Mail::Milter::Authentication::Handler::IPRev;

use strict;
use warnings;

our $VERSION = 0.4;

use base 'Mail::Milter::Authentication::Handler::Generic';

use Net::DNS;
use Net::IP;
use Sys::Syslog qw{:standard :macros};

sub connect_callback {
    my ( $self, $hostname, $sockaddr_in ) = @_;
    my $CONFIG = $self->config();
    return if ( !$CONFIG->{'check_iprev'} );
    return if ( $self->is_local_ip_address() );
    return if ( $self->is_trusted_ip_address() );
    return if ( $self->is_authenticated() );
    my $ip_address = $self->ip_address();
    my $i1         = Net::IP->new($ip_address);
    my $resolver = $self->get_object('resolver');
    my $domain;
    my $result;

    # We do not consider multiple PTR records,
    # as this is not a recomended setup
    my $packet = $resolver->query( $ip_address, 'PTR' );
    if ($packet) {
        foreach my $rr ( $packet->answer ) {
            next unless $rr->type eq "PTR";
            $domain = $rr->rdatastr;
        }
    }
    else {
        $self->log_error(
                'DNS PTR query failed for '
              . $ip_address
              . ' with '
              . $resolver->errorstring );
    }

    my $a_error;
    if ($domain) {
        my $packet = $resolver->query( $domain, 'A' );
        if ($packet) {
          APACKET:
            foreach my $rr ( $packet->answer ) {
                next unless $rr->type eq "A";
                my $address    = $rr->rdatastr;
                my $i2         = Net::IP->new($address);
                my $is_overlap = $i1->overlaps($i2) || 0;
                if ( $is_overlap == $IP_IDENTICAL ) {
                    $result = 'pass';
                    last APACKET;
                }
            }
        }
        else {
            # Don't log this right now, might be an AAAA only host.
            $a_error =
                'DNS A query failed for '
              . $domain
              . ' with '
              . $resolver->errorstring;
        }
    }

    if ( $domain && !$result ) {
        my $packet = $resolver->query( $domain, 'AAAA' );
        if ($packet) {
          APACKET:
            foreach my $rr ( $packet->answer ) {
                next unless $rr->type eq "AAAA";
                my $address    = $rr->rdatastr;
                my $i2         = Net::IP->new($address);
                my $is_overlap = $i1->overlaps($i2) || 0;
                if ( $is_overlap == $IP_IDENTICAL ) {
                    $result = 'pass';
                    last APACKET;
                }
            }
        }
        else {
            # Log A errors now, as they become relevant if AAAA also fails.
            $self->log_error( $a_error ) if $a_error;
            $self->log_error(
                    'DNS AAAA query failed for '
                  . $domain
                  . ' with '
                  . $resolver->errorstring );
        }
    }

    if ( !$result ) {
        $result = 'fail';
    }

    if ( !$domain ) {
        $result = 'fail';
        $domain = 'NOT FOUND';
    }

    $domain =~ s/\.$//;

    if ( $result eq 'pass' ) {
        $self->{'verified_ptr'} = $domain;
    }

    $self->dbgout( 'IPRevCheck', $result, LOG_DEBUG );
    my $header =
        $self->format_header_entry( 'iprev',        $result ) . ' '
      . $self->format_header_entry( 'policy.iprev', $ip_address ) . ' ' . '('
      . $self->format_header_comment($domain) . ')';
    $self->add_c_auth_header($header);

}

1;
