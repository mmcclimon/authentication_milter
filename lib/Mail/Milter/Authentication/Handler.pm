package Mail::Milter::Authentication::Handler;
use strict;
use warnings;
# VERSION

=head1 DESCRIPTION

Handle the milter requests and pass off to individual handlers

=cut

use Digest::MD5 qw{ md5_hex };
use English qw{ -no_match_vars };
use Clone qw{ clone };
use Mail::SPF;
use MIME::Base64;
use Net::DNS::Resolver;
use Net::IP;
use Sys::Syslog qw{:standard :macros};
use Sys::Hostname;
use Time::HiRes qw{ ualarm gettimeofday };

use Mail::Milter::Authentication::Constants qw { :all };
use Mail::Milter::Authentication::Config;
use Mail::Milter::Authentication::Exception;
use Mail::AuthenticationResults 1.20180328;
use Mail::AuthenticationResults::Header;
use Mail::AuthenticationResults::Header::AuthServID;

our $TestResolver; # For Testing

=constructor I<new( $thischild )>

my $object = Mail::Milter::Authentication::Handler->new( $thischild );

Takes the argument of the current Mail::Milter::Authentication object
and creates a new handler object.

=cut

sub new {
    my ( $class, $thischild ) = @_;
    my $self = {
        'thischild' => $thischild,
    };
    bless $self, $class;
    return $self;
}

=method I<get_version()>

Return the version of this handler

=cut

sub get_version {
    my ( $self ) = @_;
    {
        no strict 'refs'; ## no critic;
        return ${ ref( $self ) . "::VERSION" }; # no critic;
    }
    return;
}

=metric_method I<get_json( $file )>

Return json data from external file

=cut

sub get_json {
    my ( $self, $file ) = @_;
    my $basefile = __FILE__;
    $basefile =~ s/Handler\.pm$/Handler\/$file/;
    $basefile .= '.json';
    if ( ! -e $basefile ) {
        die 'json file ' . $file . ' not found';
    }
    open my $InF, '<', $basefile;
    my @Content = <$InF>;
    close $InF;
    return join( q{}, @Content );
}

=metric_method I<metric_register( $id, $help )>

Register a metric type

=cut

sub metric_register {
    my ( $self, $id, $help ) = @_;
    $self->{'thischild'}->{'metric'}->register( $id, $help, $self->{'thischild'} );
    return;
}

=metric_method I<metric_count( $id, $labels, $count )>

Increment a metrics counter by $count (defaults to 1 if undef)

=cut

sub metric_count {
    my ( $self, $count_id, $labels, $count ) = @_;
    $labels = {} if ! defined $labels;
    $count = 1 if ! defined $count;

    my $metric = $self->{'thischild'}->{'metric'};
    $metric->count({
        'count_id' => $count_id,
        'labels'   => $labels,
        'server'   => $self->{'thischild'},
        'count'    => $count,
    });
    return;
}

=metric_method I<metric_send()>

Send metrics to the parent

=cut

sub metric_send {
    my ( $self ) = @_;
    $self->{'thischild'}->{'metric'}->send( $self->{ 'thischild' });
    return;
}

=rbl_method I<rbl_check_ip( $ip, $list )>

Check the given IP address against an rbl list.

Returns true is listed.

=cut

sub rbl_check_ip {
    my ( $self, $ip, $list ) = @_;

    my $lookup_ip;

    # Reverse the IP
    if ( $ip->version() == 4 ) {
        $lookup_ip = join( '.', reverse( split( /\./, $ip->ip() ) ) );
    }
    elsif ( $ip->version() == 6 ) {
        my $ip_string = $ip->ip();
        $ip_string =~ s/://g;
        $lookup_ip = join( '.', reverse( split( '', $ip_string ) ) );
    }

    return 0 if ! $lookup_ip;
    return $self->rbl_check_domain( $lookup_ip, $list );
}

=rbl_method I<rbl_check_domain( $domain, $list )>

Check the given domain against an rbl list.

Returns true is listed.

=cut

sub rbl_check_domain {
    my ( $self, $domain, $list ) = @_;
    my $resolver = $self->get_object( 'resolver' );
    my $lookup = join( '.', $domain, $list );
    my $packet = $resolver->query( $lookup, 'A' );

    if ($packet) {
        foreach my $rr ( $packet->answer ) {
            if (  lc $rr->type eq 'a' ) {
                return 1;
            }
        }
    }
    return 0;
}

=timeout_method I<get_microseconds()>

Return the current time in microseconds

=cut

sub get_microseconds {
    my ( $self ) = @_;
    my ($seconds, $microseconds) = gettimeofday;
    return ( ( $seconds * 1000000 ) + $microseconds );
}

=timeout_method I<get_microseconds_since( $time )>

Return the number of microseconds since the given time (in microseconds)

=cut

sub get_microseconds_since {
    my ( $self, $since ) = @_;
    my $now = $self->get_microseconds();
    my $elapsed = $now - $since;
    $elapsed = 1 if $elapsed == 0; # Always return at least 1
    return $elapsed;
}

# Top Level Callbacks

=metric_method I<register_metrics()>

Return details of the metrics this module exports.

=cut

sub register_metrics {
    return {
        'connect_total'           => 'The number of connections made to authentication milter',
        'callback_error_total'    => 'The number of errors in callbacks',
        'time_microseconds_total' => 'The time in microseconds spent in various handlers',
    };
}

=callback_method I<top_setup_callback()>

Top level handler for handler setup.

=cut

sub top_setup_callback {

    my ( $self ) = @_;
    $self->status('setup');
    $self->dbgout( 'CALLBACK', 'Setup', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );

    my $callbacks = $self->get_callbacks( 'setup' );
    foreach my $handler ( @$callbacks ) {
        $self->dbgout( 'CALLBACK', 'Setup ' . $handler, LOG_DEBUG );
        my $start_time = $self->get_microseconds();
        $self->get_handler($handler)->setup_callback();
        $self->metric_count( 'time_microseconds_total', { 'callback' => 'setup', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
    }
    $self->status('postsetup');
    return;
}

=timeout_method I<is_exception_type( $exception )>

Given a Mail::Milter::Authentication::Exception object, this return
the exception object type.
Otherwise returns undef.

=cut

sub is_exception_type {
    my ( $self, $exception ) = @_;
    return if ! defined $exception;
    return if ! $exception;
    return if ref $exception ne 'Mail::Milter::Authentication::Exception';
    my $Type = $exception->{ 'Type' } || 'Unknown';
    return $Type;
}

=timeout_method I<handle_exception( $exception )>

Handle exceptions thrown, this method currently handles the
timeout type, by re-throwing the exception.

Should be called in Handlers when handling local exceptions, such that the
higher level timeout exceptions are properly handled.

=cut

sub handle_exception {
    my ( $self, $exception ) = @_;
    my $Type = $self->is_exception_type( $exception );
    return if ! $Type;
    die $exception if $Type eq 'Timeout';
    #my $Text = $exception->{ 'Text' } || 'Unknown';
    return;
}

=timeout_method I<get_time_remaining()>

Return the time remaining (in microseconds) for the current Handler section level
callback timeout.

=cut

sub get_time_remaining {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    return if ! exists $top_handler->{ 'timeout_at' };
    my $now = $self->get_microseconds();
    my $remaining = $top_handler->{ 'timeout_at' } - $now;
    # can be zero or -ve
    return $remaining;
}

=timeout_method I<set_alarm( $microseconds )>

Set a timeout alarm for $microseconds, and set the time remaining
in the top level handler object.

=cut

sub set_alarm {
    my ( $self, $microseconds ) = @_;
    my $top_handler = $self->get_top_handler();
    $self->dbgout( 'Timeout set', $microseconds, LOG_DEBUG );
    ualarm( $microseconds );
    if ( $microseconds == 0 ) {
        delete $top_handler->{ 'timeout_at' };
    }
    else {
        $top_handler->{ 'timeout_at' } = $self->get_microseconds() + ( $microseconds );
    }
    return;
}

=timeout_method I<set_handler_alarm( $microseconds )>

Set an alarm for $microseconds, or the current time remaining for the section callback, whichever
is the lower. This should be used in Handler timeouts to ensure that a local timeout never goes for
longer than the current handler section, or protocol section level timeout.

=cut

sub set_handler_alarm {
    # Call this in a handler to set a local alarm, will take the lower value
    # of the microseconds passed in, or what is left of a higher level timeout.
    my ( $self, $microseconds ) = @_;
    my $remaining = $self->get_time_remaining();
    if ( $remaining < $microseconds ) {
        # This should already be set of course, but for clarity...
        $self->dbgout( 'Handler tmeout set (remaining used)', $remaining, LOG_DEBUG );
        ualarm( $remaining );
    }
    else {
        $self->dbgout( 'Handler tmeout set', $microseconds, LOG_DEBUG );
        ualarm( $microseconds );
    }
    return;
}

=timeout_method I<reset_alarm()>

Reset the alarm to the current time remaining in the section or protocol level timeouts.

This should be called in Handlers after local timeouts have completed, to reset the higher level
timeout alarm value.

=cut

sub reset_alarm {
    # Call this after any local handler timeouts to reset to the overall value remaining
    my ( $self ) = @_;
    my $remaining = $self->get_time_remaining();
    $self->dbgout( 'Timeout reset', $remaining, LOG_DEBUG );
    if ( $remaining < 1 ) {
        # We have already timed out!
        die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Reset check timeout' });
    }
    ualarm( $remaining );
    return;
}

=timeout_method I<clear_overall_timeout()>

Clear the current Handler level timeout, should be called from the Protocol layer, never from the Handler layer.

=cut

sub clear_overall_timeout {
    my ( $self ) = @_;
    $self->dbgout( 'Overall timeout', 'Clear', LOG_DEBUG );
    my $top_handler = $self->get_top_handler();
    delete $top_handler->{ 'overall_timeout' };
    return;
}

=timeout_method I<set_overall_timeout( $microseconds )>

Set the time in microseconds after which the Handler layer should timeout, called from the Protocol later, never from the Handler layer.

=cut

sub set_overall_timeout {
    my ( $self, $microseconds ) = @_;
    my $top_handler = $self->get_top_handler();
    $self->dbgout( 'Overall timeout', $microseconds, LOG_DEBUG );
    $top_handler->{ 'overall_timeout' } = $self->get_microseconds() + $microseconds;
    return;
}

=timeout_method I<get_type_timeout( $type )>

For a given timeout type, return the configured timeout value, or the current handler level timeout, whichever is lower.

=cut

sub get_type_timeout {
    my ( $self, $type ) = @_;

    my @log;
    push @log, "Type: $type";

    my $effective;

    my $timeout;
    my $config = $self->config();
    if ( $config->{ $type . '_timeout' } ) {
        $timeout = $config->{ $type . '_timeout' } * 1000000;
        $effective = $timeout;
        push @log, "Section: $timeout";
    }

    my $remaining;
    my $top_handler = $self->get_top_handler();
    if ( my $overall_timeout = $top_handler->{ 'overall_timeout' } ) {
        my $now = $self->get_microseconds();
        $remaining = $overall_timeout - $now;
        push @log, "Overall: $remaining";
        if ( $remaining < 1 ) {
            push @log, "Overall Timedout";
            $remaining = 10; # arb low value;
        }
    }

    if ( $remaining ) {
        if ( $timeout ) {
            if ( $remaining < $timeout ) {
                $effective = $remaining;
            }
        }
        else {
            $effective = $remaining;
        }
    }

    push @log, "Effective: $effective" if $effective;

    $self->dbgout( 'Timeout set', join( ', ', @log ), LOG_DEBUG );

    return $effective;
}

=timeout_method I<check_timeout()>

Manually check the current timeout, and throw if it has passed.

=cut

sub check_timeout {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    return if ! exists $top_handler->{ 'timeout_at' };
    return if $top_handler->{ 'timeout_at' } >= $self->get_microseconds();
    delete $top_handler->{ 'timeout_at' };
    ualarm( 0 );
    die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Manual check timeout' });
}

=callback_method I<top_connect_callback( $hostname, $ip )>

Top level handler for the connect event.

=cut

sub top_connect_callback {

    # On Connect
    my ( $self, $hostname, $ip ) = @_;
    $self->metric_count( 'connect_total' );
    $self->status('connect');
    $self->dbgout( 'CALLBACK', 'Connect', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $self->clear_reject_mail();
    $self->clear_defer_mail();
    $self->clear_quarantine_mail();
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Connect callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'connect' ) ) {
            $self->set_alarm( $timeout );
        }

        $self->dbgout( 'ConnectFrom', $ip->ip(), LOG_DEBUG );
        $self->{'raw_ip_object'} = $ip;

        if ( exists ( $config->{ 'ip_map' } ) ) {
            foreach my $ip_map ( sort keys %{ $config->{ 'ip_map' } } ) {
                my $map_obj = Net::IP->new( $ip_map );
                my $is_overlap = $ip->overlaps($map_obj) || 0;
                if (
                       $is_overlap == $IP_A_IN_B_OVERLAP
                    || $is_overlap == $IP_B_IN_A_OVERLAP     # Should never happen
                    || $is_overlap == $IP_PARTIAL_OVERLAP    # Should never happen
                    || $is_overlap == $IP_IDENTICAL
                  )
                {
                    if ( exists ( $config->{ 'ip_map' }->{ $ip_map }->{ 'ip' } ) ) {
                        $ip = Net::IP->new( $config->{ 'ip_map' }->{ $ip_map }->{ 'ip' } );
                        $self->dbgout( 'ConnectFromRemapped', $self->{'raw_ip_object'}->ip() . ' > ' . $ip->ip(), LOG_DEBUG );
                        last;
                    }
                }
            }
        }

        $self->{'ip_object'} = $ip;

        my $callbacks = $self->get_callbacks( 'connect' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'Connect ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->connect_callback( $hostname, $ip ); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Connect callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'connect', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'connect', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'Connect callback error ' . $type . ' - ' . $error->{ 'Text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'connect', 'type' => $type } );
        }
        else {
            $self->log_error( 'Connect callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'connect' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->status('postconnect');
    return $self->get_return();
}

=callback_method I<top_helo_callback( $helo_host )>

Top level handler for the HELO event.

=cut

sub top_helo_callback {

    # On HELO
    my ( $self, $helo_host ) = @_;
    $self->status('helo');
    $self->dbgout( 'CALLBACK', 'Helo', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $helo_host = q{} if ! defined $helo_host;
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'HELO callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'command' ) ) {
            $self->set_alarm( $timeout );
        }

        # Take only the first HELO from a connection
        if ( !( $self->{'helo_name'} ) ) {

            $self->{'raw_helo_name'} = $helo_host;
            if ( exists ( $config->{ 'ip_map' } ) ) {
                my $ip_object = $self->{ 'raw_ip_object' };
                foreach my $ip_map ( sort keys %{ $config->{ 'ip_map' } } ) {
                    my $map_obj = Net::IP->new( $ip_map );
                    my $is_overlap = $ip_object->overlaps($map_obj) || 0;
                    if (
                           $is_overlap == $IP_A_IN_B_OVERLAP
                        || $is_overlap == $IP_B_IN_A_OVERLAP     # Should never happen
                        || $is_overlap == $IP_PARTIAL_OVERLAP    # Should never happen
                        || $is_overlap == $IP_IDENTICAL
                      )
                    {
                        my $mapped_to = $config->{ 'ip_map' }->{ $ip_map };
                        if ( exists ( $config->{ 'ip_map' }->{ $ip_map }->{ 'helo' } ) ) {
                            $helo_host = $config->{ 'ip_map' }->{ $ip_map }->{ 'helo' };
                            $self->dbgout( 'HELORemapped', $self->{'raw_helo_name'} . ' > ' . $helo_host, LOG_DEBUG );
                            last;
                        }
                    }
                }
            }

            $self->{'helo_name'} = $helo_host;

            my $callbacks = $self->get_callbacks( 'helo' );
            foreach my $handler ( @$callbacks ) {
                $self->dbgout( 'CALLBACK', 'Helo ' . $handler, LOG_DEBUG );
                my $start_time = $self->get_microseconds();
                eval{ $self->get_handler($handler)->helo_callback($helo_host); };
                if ( my $error = $@ ) {
                    $self->handle_exception( $error );
                    $self->log_error( 'HELO callback error ' . $error );
                    $self->exit_on_close();
                    $self->tempfail_on_error();
                    $self->metric_count( 'callback_error_total', { 'stage' => 'helo', 'handler' => $handler } );
                }
                $self->metric_count( 'time_microseconds_total', { 'callback' => 'helo', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
                $self->check_timeout();
            }
        }
        else {
            $self->dbgout('Multiple HELO callbacks detected and ignored', $self->{'helo_name'} . ' / ' . $helo_host, LOG_DEBUG );
        }

        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'HELO error ' . $type . ' - ' . $error->{ 'Text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'helo', 'type' => $type } );
        }
        else {
            $self->log_error( 'HELO callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'helo' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->status('posthelo');
    return $self->get_return();
}

=callback_method I<top_envfrom_callback( $env_from )>

Top level handler for the MAIL FROM event.

=cut

sub top_envfrom_callback {

    # On MAILFROM
    #...
    my ( $self, $env_from ) = @_;
    $self->status('envfrom');
    $self->dbgout( 'CALLBACK', 'EnvFrom', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $env_from = q{} if ! defined $env_from;
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'EnvFrom callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'command' ) ) {
            $self->set_alarm( $timeout );
        }

        # Reset private data for this MAIL transaction
        delete $self->{'auth_headers'};
        delete $self->{'pre_headers'};
        delete $self->{'add_headers'};

        my $callbacks = $self->get_callbacks( 'envfrom' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'EnvFrom ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval { $self->get_handler($handler)->envfrom_callback($env_from); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Env From callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'envfrom', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'envfrom', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'EnvFrom error ' . $type . ' - ' . $error->{ 'Text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'envfrom', 'type' => $type } );
        }
        else {
            $self->log_error( 'EnvFrom callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'envfrom' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->status('postenvfrom');
    return $self->get_return();
}

=callback_method I<top_envrcpt_callback( $env_to )>

Top level handler for the RCPT TO event.

=cut

sub top_envrcpt_callback {

    # On RCPTTO
    #...
    my ( $self, $env_to ) = @_;
    $self->status('envrcpt');
    $self->dbgout( 'CALLBACK', 'EnvRcpt', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $env_to = q{} if ! defined $env_to;
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'EnvRcpt callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'command' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'envrcpt' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'EnvRcpt ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->envrcpt_callback($env_to); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Rcpt To callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'rcptto', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'rcptto', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'EnvRcpt error ' . $type . ' - ' . $error->{ 'Text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'rcptto', 'type' => $type } );
        }
        else {
            $self->log_error( 'EnvRcpt callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'rcptto' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->status('postenvrcpt');
    return $self->get_return();
}

=callback_method  I<top_header_callback( $header, $value )>

Top level handler for the BODY header event.

=cut

sub top_header_callback {

    # On Each Header
    my ( $self, $header, $value ) = @_;
    $self->status('header');
    $self->dbgout( 'CALLBACK', 'Header', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $value = q{} if ! defined $value;
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Header callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'content' ) ) {
            $self->set_alarm( $timeout );
        }
        if ( my $error = $@ ) {
            $self->dbgout( 'inline error $error', '', LOG_DEBUG );
        }

        my $callbacks = $self->get_callbacks( 'header' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'Header ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->header_callback( $header, $value ); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Header callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'header', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'header', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'Header error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'header', 'type' => $type } );
        }
        else {
            $self->log_error( 'Header callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'header' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->status('postheader');
    return $self->get_return();
}

=callback_method I<top_eoh_callback()>

Top level handler for the BODY end of headers event.

=cut

sub top_eoh_callback {

    # On End of headers
    my ($self) = @_;
    $self->status('eoh');
    $self->dbgout( 'CALLBACK', 'EOH', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'EOH callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'content' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'eoh' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'EOH ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->eoh_callback(); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'EOH callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'eoh', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'eoh', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'EOH error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'eoh', 'type' => $type } );
        }
        else {
            $self->log_error( 'EOH callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'eoh' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->dbgoutwrite();
    $self->status('posteoh');
    return $self->get_return();
}

=callback_method I<top_body_callback( $body_chunk )>

Top level handler for the BODY body chunk event.

=cut

sub top_body_callback {

    # On each body chunk
    my ( $self, $body_chunk ) = @_;
    $self->status('body');
    $self->dbgout( 'CALLBACK', 'Body', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Body callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'content' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'body' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'Body ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->body_callback( $body_chunk ); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Body callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'body', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'body', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'Body error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'body', 'type' => $type } );
        }
        else {
            $self->log_error( 'Body callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'body' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->dbgoutwrite();
    $self->status('postbody');
    return $self->get_return();
}

=callback_method I<top_eom_callback()>

Top level handler for the BODY end of message event.

=cut

sub top_eom_callback {

    # On End of Message
    my ($self) = @_;
    $self->status('eom');
    $self->dbgout( 'CALLBACK', 'EOM', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'EOM callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'content' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'eom' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'EOM ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->eom_callback(); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'EOM callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'eom', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'eom', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'EOM error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'eom', 'type' => $type } );
        }
        else {
            $self->log_error( 'EOM callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'eom' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->apply_policy();
    $self->add_headers();
    $self->dbgoutwrite();
    $self->status('posteom');
    return $self->get_return();
}

=callback_method I<apply_policy()>

Apply policy to the message, currently a nop.

=cut

sub apply_policy {
    my ($self) = @_;

    my @auth_headers;
    my $top_handler = $self->get_top_handler();
    if ( exists( $top_handler->{'c_auth_headers'} ) ) {
        @auth_headers = @{ $top_handler->{'c_auth_headers'} };
    }
    if ( exists( $top_handler->{'auth_headers'} ) ) {
        @auth_headers = ( @auth_headers, @{ $top_handler->{'auth_headers'} } );
    }

    #my $parsed_headers = Mail::AuthenticationResults::Parser->new( \@auth_headers );;

    #use Data::Dumper;
    #print Dumper \@structured_headers;

    return;
}

=callback_method I<top_abort_callback()>

Top level handler for the abort event.

=cut

sub top_abort_callback {

    # On any out of our control abort
    my ($self) = @_;
    $self->status('abort');
    $self->dbgout( 'CALLBACK', 'Abort', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Abord callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'command' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'abort' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'Abort ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->abort_callback(); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Abort callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'abort', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'abort', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'Abort error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'abort', 'type' => $type } );
        }
        else {
            $self->log_error( 'Abort callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'abort' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->status('postabort');
    return $self->get_return();
}

=callback_method I<top_close_callback()>

Top level handler for the close event.

=cut

sub top_close_callback {

    # On end of connection
    my ($self) = @_;
    $self->status('close');
    $self->dbgout( 'CALLBACK', 'Close', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $self->clear_reject_mail();
    $self->clear_defer_mail();
    $self->clear_quarantine_mail();
    my $config = $self->config();
    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'Close callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'command' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'close' );
        foreach my $handler ( @$callbacks ) {
            $self->dbgout( 'CALLBACK', 'Close ' . $handler, LOG_DEBUG );
            my $start_time = $self->get_microseconds();
            eval{ $self->get_handler($handler)->close_callback(); };
            if ( my $error = $@ ) {
                $self->handle_exception( $error );
                $self->log_error( 'Close callback error ' . $error );
                $self->exit_on_close();
                $self->tempfail_on_error();
                $self->metric_count( 'callback_error_total', { 'stage' => 'close', 'handler' => $handler } );
            }
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'close', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'Close error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'close', 'type' => $type } );
        }
        else {
            $self->log_error( 'Close callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'close' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    delete $self->{'helo_name'};
    delete $self->{'raw_helo_name'};
    delete $self->{'c_auth_headers'};
    delete $self->{'auth_headers'};
    delete $self->{'pre_headers'};
    delete $self->{'add_headers'};
    delete $self->{'ip_object'};
    delete $self->{'raw_ip_object'};
    $self->dbgoutwrite();
    $self->clear_all_symbols();
    $self->status('postclose');
    return $self->get_return();
}

=callback_method I<top_addheader_callback()>

Top level handler for the add header event.

Called after the Authentication-Results header has been added, but before any other headers.

=cut

sub top_addheader_callback {
    my ( $self ) = @_;
    my $config = $self->config();

    eval {
        local $SIG{'ALRM'} = sub{ die Mail::Milter::Authentication::Exception->new({ 'Type' => 'Timeout', 'Text' => 'AddHeader callback timeout' }) };
        if ( my $timeout = $self->get_type_timeout( 'addheader' ) ) {
            $self->set_alarm( $timeout );
        }

        my $callbacks = $self->get_callbacks( 'addheader' );
        foreach my $handler ( @$callbacks ) {
            my $start_time = $self->get_microseconds();
            $self->get_handler($handler)->addheader_callback($self);
            $self->metric_count( 'time_microseconds_total', { 'callback' => 'addheader', 'handler' => $handler }, $self->get_microseconds_since( $start_time ) );
            $self->check_timeout();
        }
        $self->set_alarm(0);
    };
    if ( my $error = $@ ) {
        if ( my $type = $self->is_exception_type( $error ) ) {
            $self->log_error( 'AddHeader error ' . $type . ' - ' . $error->{ 'text' } );
            $self->metric_count( 'callback_error_total', { 'stage' => 'addheader', 'type' => $type } );
        }
        else {
            $self->log_error( 'AddHeader callback error ' . $error );
            $self->metric_count( 'callback_error_total', { 'stage' => 'addheader' } );
        }
        $self->exit_on_close();
        $self->tempfail_on_error();
    }

    return;
}


# Other methods

=method I<status( $status )>

Set the status of the current child as visible by ps.

=cut

sub status {
    my ($self, $status) = @_;
    my $count = $self->{'thischild'}->{'count'};
    if ( exists ( $self->{'thischild'}->{'smtp'} ) ) {
        if ( $self->{'thischild'}->{'smtp'}->{'count'} ) {
            $count .= '.' . $self->{'thischild'}->{'smtp'}->{'count'};
        }
    }
    if ( $status ) {
        $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':processing:' . $status . '(' . $count . ')';
    }
    else {
        $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':processing(' . $count . ')';
    }
    return;
}

=method I<config()>

Return the configuration hashref.

=cut

sub config {
    my ($self) = @_;
    return $self->{'thischild'}->{'config'};
}

=method I<handler_config( $type )>

Return the configuration for the current handler.

=cut

sub handler_config {
    my ($self) = @_;
    my $type = $self->handler_type();
    return if ! $type;
    if ( $self->is_handler_loaded( $type ) ) {
        my $config = $self->config();
        my $handler_config = $config->{'handlers'}->{$type};

        if ( exists( $config->{ '_external_callback_processor' } ) ) {
            if ( $config->{ '_external_callback_processor' }->can( 'handler_config' ) ) {
                $handler_config = clone $handler_config;
                $config->{ '_external_callback_processor' }->handler_config( $type, $handler_config );
            }
        }

        return $handler_config;
    }
    return;
}

=method I<handler_type()>

Return the current handler type.

=cut

sub handler_type {
    my ($self) = @_;
    my $type = ref $self;
    if ( $type eq 'Mail::Milter::Authentication::Handler' ) {
        return 'Handler';
    }
    elsif ( $type =~ /^Mail::Milter::Authentication::Handler::(.*)/ ) {
        my $handler_type = $1;
        return $handler_type;
    }
    else {
        return undef; ## no critic
    }
}

=method I<set_return( $code )>

Set the return code to be passed back to the MTA.

=cut

sub set_return {
    my ( $self, $return ) = @_;
    my $top_handler = $self->get_top_handler();
    $top_handler->{'return_code'} = $return;
    return;
}

=method I<get_return()>

Get the current return code.

=cut

sub get_return {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    if ( defined $self->get_reject_mail() ) {
        return $self->smfis_reject();
    }
    elsif ( defined $self->get_defer_mail() ) {
        return $self->smfis_tempfail();
    }
    elsif ( defined $self->get_quarantine_mail() ) {
        ## TODO Implement this.
    }
    return $top_handler->{'return_code'};
}

=method I<get_reject_mail()>

Get the reject mail reason (or undef)

=cut

sub get_reject_mail {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    return $top_handler->{'reject_mail'};
}

=method I<clear_reject_mail()>

Clear the reject mail reason

=cut

sub clear_reject_mail {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    delete $top_handler->{'reject_mail'};
    return;
}

=method I<get_defer_mail()>

Get the defer mail reason (or undef)

=cut

sub get_defer_mail {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    return $top_handler->{'defer_mail'};
}

=method I<clear_defer_mail()>

Clear the defer mail reason

=cut

sub clear_defer_mail {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    delete $top_handler->{'defer_mail'};
    return;
}


=method I<get_quarantine_mail()>

Get the quarantine mail reason (or undef)

=cut

sub get_quarantine_mail {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    return $top_handler->{'quarantine_mail'};
}

=method I<clear_quarantine_mail()>

Clear the quarantine mail reason

=cut

sub clear_quarantine_mail {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    delete $top_handler->{'quarantine_mail'};
    return;
}

=method I<get_top_handler()>

Return the current top Handler object.

=cut

sub get_top_handler {
    my ($self) = @_;
    my $thischild = $self->{'thischild'};
    my $object = $thischild->{'handler'}->{'_Handler'};
    return $object;
}

=method I<is_handler_loaded( $name )>

Check if the named handler is loaded.

=cut

sub is_handler_loaded {
    my ( $self, $name ) = @_;
    my $config = $self->config();
    if ( exists ( $config->{'handlers'}->{$name} ) ) {
        return 1;
    }
    return 0;
}

=method I<get_handler( $name )>

Return the named handler object.

=cut

sub get_handler {
    my ( $self, $name ) = @_;
    my $thischild = $self->{'thischild'};
    my $object = $thischild->{'handler'}->{$name};
    return $object;
}

=method I<get_callbacks( $callback )>

Return the list of handlers which have callbacks for the given event in the order they must be called in.

=cut

sub get_callbacks {
    my ( $self, $callback ) = @_;
    my $thischild = $self->{'thischild'};
    return $thischild->{'callbacks_list'}->{$callback};
}

=method I<set_object_maker( $name, $ref )>

Register an object maker for type 'name'

=cut

sub set_object_maker {
    my ( $self, $name, $ref ) = @_;
    my $thischild = $self->{'thischild'};
    return if $thischild->{'object_maker'}->{$name};
    $thischild->{'object_maker'}->{$name} = $ref;
    return;
}

=method I<get_object( $name )>

Return the named object from the object store.

Object 'resolver' will be created if it does not already exist.

Object 'spf_server' will be created by the SPF handler if it does not already exist.

Handlers may register makers for other types as required.

=cut

sub get_object {
    my ( $self, $name ) = @_;

    my $thischild = $self->{'thischild'};
    my $object = $thischild->{'object'}->{$name};
    if ( ! $object ) {

        if ( exists( $thischild->{'object_maker'}->{$name} ) ) {
            my $maker = $thischild->{'object_maker'}->{$name};
            &$maker( $self, $name );
        }

        elsif ( $name eq 'resolver' ) {
            $self->dbgout( 'Object created', $name, LOG_DEBUG );
            my $config = $self->config();
            my $timeout           = $config->{'dns_timeout'}           || 8;
            my $dns_retry         = $config->{'dns_retry'}             || 2;
            my $resolvers         = $config->{'dns_resolvers'}         || [];
            if ( defined $TestResolver ) {
                $object = $TestResolver;
                warn "Using FAKE TEST DNS Resolver - I Hope this isn't production!";
                # If it is you better know what you're doing!
            }
            else {
                $object = Net::DNS::Resolver->new(
                    'udp_timeout'       => $timeout,
                    'tcp_timeout'       => $timeout,
                    'retry'             => $dns_retry,
                    'nameservers'       => $resolvers,
                );
                $object->udppacketsize(1240);
                $object->persistent_udp(1);
            }
            $thischild->{'object'}->{$name} = {
                'object'  => $object,
                'destroy' => 0,
            };
        }

    }
    return $thischild->{'object'}->{$name}->{'object'};
}

=method I<set_object( $name, $object, $destroy )>

Store the given object in the object store with the given name.

If $destroy then the object will be destroyed when the connection to the child closes

=cut

sub set_object {
    my ( $self, $name, $object, $destroy ) = @_;
    my $thischild = $self->{'thischild'};
    $self->dbgout( 'Object set', $name, LOG_DEBUG );
    $thischild->{'object'}->{$name} = {
        'object'  => $object,
        'destroy' => $destroy,
    };
    return;
}

=method I<destroy_object( $name )>

Remove the reference to the named object from the object store.

=cut

sub destroy_object {
    my ( $self, $name ) = @_;
    my $thischild = $self->{'thischild'};

    # Objects may be set to not be destroyed,
    # eg. resolver and spf_server are not
    # destroyed for performance reasons
    return if ! $thischild->{'object'}->{$name}->{'destroy'};
    return if ! $thischild->{'object'}->{$name};
    $self->dbgout( 'Object destroyed', $name, LOG_DEBUG );
    delete $thischild->{'object'}->{$name};
    return;
}

=method I<destroy_all_objects()>

Remove the references to all objects currently stored in the object store.

Certain objects (resolver and spf_server) are not destroyed for performance reasons.

=cut

sub destroy_all_objects {
    # Unused!
    my ( $self ) = @_;
    my $thischild = $self->{'thischild'};
    foreach my $name ( keys %{ $thischild->{'object'} } )
    {
        $self->destroy_object( $name );
    }
    return;
}

=method I<exit_on_close()>

Exit this child once it has completed, do not process further requests with this child.

=cut

sub exit_on_close {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    $top_handler->{'exit_on_close'} = 1;
    return;
}

=method I<reject_mail( $reason )>

Reject mail with the given reason

=cut

sub reject_mail {
    my ( $self, $reason ) = @_;
    my ( $rcode, $xcode, $message ) = split( ' ', $reason, 3 );
    if ($rcode !~ /^[5]\d\d$/ || $xcode !~ /^[5]\.\d\.\d$/ || substr($rcode, 0, 1) ne substr($xcode, 0, 1)) {
        $self->loginfo ( "Invalid reject message $reason - setting to default" );
        $reason = '550 5.0.0 Message rejected';
    }
    my $top_handler = $self->get_top_handler();
    $top_handler->{'reject_mail'} = $reason;
    return;
}

=method I<quarantine_mail( $reason )>

Request quarantine mail with the given reason

=cut

sub quarantine_mail {
    my ( $self, $reason ) = @_;
    my $top_handler = $self->get_top_handler();
    $top_handler->{'quarantine_mail'} = $reason;
    return;
}

=method I<defer_mail( $reason )>

Defer mail with the given reason

=cut

sub defer_mail {
    my ( $self, $reason ) = @_;
    my ( $rcode, $xcode, $message ) = split( ' ', $reason, 3 );
    if ($rcode !~ /^[4]\d\d$/ || $xcode !~ /^[4]\.\d\.\d$/ || substr($rcode, 0, 1) ne substr($xcode, 0, 1)) {
        $self->loginfo ( "Invalid defer message $reason - setting to default" );
        $reason = '450 4.0.0 Message deferred';
    }
    my $top_handler = $self->get_top_handler();
    $top_handler->{'defer_mail'} = $reason;
    return;
}

=method I<clear_all_symbols()>

Clear the symbol store.

=cut

sub clear_all_symbols {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();
    delete $top_handler->{'symbols'};
    return;
}

=method I<clear_symbols()>

Clear the symbol store but do not remove the Connect symbols.

=cut

sub clear_symbols {
    my ( $self ) = @_;
    my $top_handler = $self->get_top_handler();

    my $connect_symbols;
    if ( exists ( $top_handler->{'symbols'} ) ) {
        if ( exists ( $top_handler->{'symbols'}->{'C'} ) ) {
            $connect_symbols = $top_handler->{'symbols'}->{'C'};
        }
    }

    delete $top_handler->{'symbols'};

    if ( $connect_symbols ) {
        $top_handler->{'symbols'} = {
            'C' => $connect_symbols,
        };
    }

    return;
}

=method I<set_symbol( $code, $key, $value )>

Store the key value pair in the symbol store with the given code (event stage).

=cut

sub set_symbol {
    my ( $self, $code, $key, $value ) = @_;
    $self->dbgout( 'SetSymbol', "$code: $key: $value", LOG_DEBUG );
    my $top_handler = $self->get_top_handler();
    if ( ! exists ( $top_handler->{'symbols'} ) ) {
        $top_handler->{'symbols'} = {};
    }
    if ( ! exists ( $top_handler->{'symbols'}->{$code} ) ) {
        $top_handler->{'symbols'}->{$code} = {};
    }
    $top_handler->{'symbols'}->{$code}->{$key} = $value;;
    return;
}

=method I<get_symbol( $searchkey )>

Return a value from the symbol store, searches all codes for the given key.

=cut

sub get_symbol {
    my ( $self, $searchkey ) = @_;
    my $top_handler = $self->get_top_handler();
    my $symbols = $top_handler->{'symbols'} || {};
    foreach my $code ( keys %{$symbols} ) {
        my $subsymbols = $symbols->{$code};
        foreach my $key ( keys %{$subsymbols} ) {
            if ( $searchkey eq $key ) {
                return $subsymbols->{$key};
            }
        }
    }
    return;
}

=method I<tempfail_on_error()>

Returns a TEMP FAIL to the calling MTA if the configuration is set to do so.

Config can be set for all, authenticated, local, and trusted connections.

=cut

sub tempfail_on_error {
    my ( $self ) = @_;
    my $config = $self->config();
    if ( $self->is_authenticated() ) {
        if ( $config->{'tempfail_on_error_authenticated'} ) {
            $self->log_error('TempFail set');
            $self->set_return( $self->smfis_tempfail() );
        }
    }
    elsif ( $self->is_local_ip_address() ) {
        if ( $config->{'tempfail_on_error_local'} ) {
            $self->log_error('TempFail set');
            $self->set_return( $self->smfis_tempfail() );
        }
    }
    elsif ( $self->is_trusted_ip_address() ) {
        if ( $config->{'tempfail_on_error_trusted'} ) {
            $self->log_error('TempFail set');
            $self->set_return( $self->smfis_tempfail() );
        }
    }
    else {
        if ( $config->{'tempfail_on_error'} ) {
            $self->log_error('TempFail set');
            $self->set_return( $self->smfis_tempfail() );
        }
    }
    return;
}



# Common calls into other Handlers

=helper_method I<is_local_ip_address()>

Is the current connection from a local ip address?

Requires the LocalIP Handler to be loaded.

=cut

sub is_local_ip_address {
    my ($self) = @_;
    return 0 if ! $self->is_handler_loaded('LocalIP');
    return $self->get_handler('LocalIP')->{'is_local_ip_address'};
}

=helper_method I<is_trusted_ip_address()>

Is the current connection from a trusted ip address?

Requires the TrustedIP Handler to be loaded.

=cut

sub is_trusted_ip_address {
    my ($self) = @_;
    return 0 if ! $self->is_handler_loaded('TrustedIP');
    return $self->get_handler('TrustedIP')->{'is_trusted_ip_address'};
}

=helper_method I<is_authenticated()>

Is the current connection authenticated?

Requires the Auth Handler to be loaded.

=cut

sub is_authenticated {
    my ($self) = @_;
    return 0 if ! $self->is_handler_loaded('Auth');
    return $self->get_handler('Auth')->{'is_authenticated'};
}

=helper_method I<ip_address()>

Return the ip address of the current connection.

=cut

sub ip_address {
    my ($self) = @_;
    my $top_handler = $self->get_top_handler();
    return $top_handler->{'ip_object'}->ip();
}



# Header formatting and data methods

=helper_method I<format_ctext( $text )>

Format text as ctext for use in headers.

Deprecated.

=cut

sub format_ctext {

    # Return ctext (but with spaces intact)
    my ( $self, $text ) = @_;
    $text = q{} if ! defined $text;
    $text =~ s/\t/ /g;
    $text =~ s/\n/ /g;
    $text =~ s/\r/ /g;
    $text =~ s/\(/ /g;
    $text =~ s/\)/ /g;
    $text =~ s/\\/ /g;
    return $text;
}

=helper_method I<format_ctext_no_space( $text )>

Format text as ctext with no spaces for use in headers.

Deprecated.

=cut

sub format_ctext_no_space {
    my ( $self, $text ) = @_;
    $text = $self->format_ctext($text);
    $text =~ s/ //g;
    $text =~ s/;/_/g;
    return $text;
}

=helper_method I<format_header_comment( $comment )>

Format text as a comment for use in headers.

Deprecated.

=cut

sub format_header_comment {
    my ( $self, $comment ) = @_;
    $comment = $self->format_ctext($comment);
    return $comment;
}

=helper_method I<format_header_entry( $key, $value )>

Format text as a key value pair for use in authentication header.

Deprecated.

=cut

sub format_header_entry {
    my ( $self, $key, $value ) = @_;
    $key   = $self->format_ctext_no_space($key);
    $value = $self->format_ctext_no_space($value);
    my $string = "$key=$value";
    return $string;
}

=helper_method I<get_domain_from( $address )>

Extract a single domain from an email address.

=cut

sub get_domain_from {
    my ( $self, $address ) = @_;
    $address = q{} if ! defined $address;
    $address = $self->get_address_from($address);
    my $domain = 'localhost.localdomain';
    $address =~ s/<//g;
    $address =~ s/>//g;
    if ( $address =~ /\@/ ) {
        ($domain) = $address =~ /.*\@(.*)/;
    }
    $domain =~ s/\s//g;
    return lc $domain;
}

=helper_method I<get_domains_from( $address )>

Extract the domains from an email address as an arrayref.

=cut

sub get_domains_from {
    my ( $self, $addresstxt ) = @_;
    $addresstxt = q{} if ! defined $addresstxt;
    my $addresses = $self->get_addresses_from($addresstxt);
    my $domains = [];
    foreach my $address ( @$addresses ) {
        my $domain;
        $address =~ s/<//g;
        $address =~ s/>//g;
        if ( $address =~ /\@/ ) {
            ($domain) = $address =~ /.*\@(.*)/;
        }
        next if ! defined $domain;
        $domain =~ s/\s//g;
        push @$domains, lc $domain;
    }
    return $domains;
}

use constant IsSep => 0;
use constant IsPhrase => 1;
use constant IsEmail => 2;
use constant IsComment => 3;

=helper_method I<get_address_from( $text )>

Extract a single email address from a string.

=cut

sub get_address_from {
    my ( $self, $Str ) = @_;
    my $addresses = $self->get_addresses_from( $Str );
    return $addresses->[0];
}

=helper_method I<get_addresses_from( $text )>

Extract all email address from a string as an arrayref.

=cut

sub get_addresses_from {
    my ( $self, $Str ) = @_;
    $Str = q{} if ! defined $Str;

    if ( $Str eq q{} ) {
        $self->log_error( 'Could not parse empty address' );
        return [ $Str ];
    }

    my $IDNComponentRE = qr/[^\x20-\x2c\x2e\x2f\x3a-\x40\x5b-\x60\x7b-\x7f]+/;
    my $IDNRE = qr/(?:$IDNComponentRE\.)+$IDNComponentRE/;
    my $RFC_atom = qr/[a-z0-9\!\#\$\%\&\'\*\+\-\/\=\?\^\_\`\{\|\}\~]+/i;
    my $RFC_dotatom = qr/${RFC_atom}(?:\.${RFC_atom})*/;

    # Break everything into Tokens
    my ( @Tokens, @Types );
    TOKEN_LOOP:
    while (1) {
        if ($Str =~ m/\G\"(.*?)(?<!\\)(?:\"|\z)\s*/sgc) {
            # String " ... "
            push @Tokens, $1;
            push @Types, IsPhrase;
        }
        elsif ( $Str =~ m/\G\<(.*?)(?<!\\)(?:[>,;]|\z)\s*/sgc) {
            # String < ... >
            push @Tokens, $1;
            push @Types, IsEmail;
        }
        elsif ($Str =~ m/\G\((.*?)(?<!\\)\)\s*/sgc) {
            # String ( ... )
            push @Tokens, $1;
            push @Types, IsComment;
        }
        elsif ($Str =~ m/\G[,;]\s*/gc) {
            # Comma or semi-colon
            push @Tokens, undef;
            push @Types, IsSep;
        }
        elsif ($Str =~ m/\G$/gc) {
            # End of line
            last TOKEN_LOOP;
        }
        elsif ($Str =~ m/\G([^\s,;"<]*)\s*/gc) {
            # Anything else
            if (length $1) {
                push @Tokens, $1;
                push @Types, IsPhrase;
            }
        }
        else {
            # Incomplete line. We'd like to die, but we'll return what we can
            $self->log_error('Could not parse address ' . $Str . ' : Unknown line remainder : ' . substr( $Str, pos() ) );
            push @Tokens, substr($Str, pos($Str));
            push @Types, IsComment;
            last TOKEN_LOOP;
        }
    }

    # Now massage Tokens into [ "phrase", "emailaddress", "comment" ]
    my @Addrs;
    my ($Phrase, $Email, $Comment, $Type);
    for (my $i = 0; $i < scalar(@Tokens); $i++) {
        my ($Type, $Token) = ($Types[$i], $Tokens[$i]);

        # If  - a separator OR
        #     - email address and already got one OR
        #     - phrase and already got email address
        # then add current data as token
        if (($Type == IsSep) ||
            ($Type == IsEmail && defined($Email)) ||
            ($Type == IsPhrase && defined($Email)) ) {
            push @Addrs, $Email if defined $Email;
            ($Phrase, $Email, $Comment) = (undef, undef, undef);
        }

        # A phrase...
        if ($Type == IsPhrase) {
            # Strip '...' around token
            $Token =~ s/^'(.*)'$/$1/;
            # Strip any newlines assuming folded headers
            $Token =~ s/\r?\n//g;

            # Email like token?
            if ($Token =~ /^$RFC_dotatom\@$IDNRE$/o) {
                $Token =~ s/^\s+//;
                $Token =~ s/\s+$//;
                $Token =~ s/\s+\@/\@/;
                $Token =~ s/\@\s+/\@/;
                # Yes, check if next token is definitely email. If yes,
                #  make this a phrase, otherwise make it an email item
                if ($i+1 < scalar(@Tokens) && $Types[$i+1] == IsEmail) {
                    $Phrase = defined($Phrase) ? $Phrase . " " . $Token : $Token;
                }
                else {
                    # If we've already got an email address, add current address
                    if (defined($Email)) {
                        push @Addrs, $Email;
                        ($Phrase, $Email, $Comment) = (undef, undef, undef);
                    }
                    $Email = $Token;
                }
            }
            else {
                # No, just add as phrase
                $Phrase = defined($Phrase) ? $Phrase . " " . $Token : $Token;
            }
        }
        elsif ($Type == IsEmail) {
             # If an email, set email addr. Should be empty
             $Email = $Token;
        }
        elsif ($Type == IsComment) {
            $Comment = defined($Comment) ? $Comment . ", " . $Token : $Token;
        }
        # Must be separator, do nothing
    }

    # Add any remaining addresses
    push @Addrs, $Email if defined($Email);

    if ( ! @Addrs ) {
        # We couldn't parse, so just run with it and hope for the best
        push @Addrs, $Str;
        $self->log_error( 'Could not parse address ' . $Str );
    }

    my @TidyAddresses;
    foreach my $Address ( @Addrs ) {

        next if ( $Address =~ /\@unspecified-domain$/ );

        if ( $Address =~ /^mailto:(.*)$/ ) {
            $Address = $1;
        }

        # Trim whitelist that's possible, but not useful and
        #  almost certainly a copy/paste issue
        #  e.g. < foo @ bar.com >

        $Address =~ s/^\s+//;
        $Address =~ s/\s+$//;
        $Address =~ s/\s+\@/\@/;
        $Address =~ s/\@\s+/\@/;

        push @TidyAddresses, $Address;
    }

    if ( ! @TidyAddresses ) {
        # We really couldn't parse, so just run with it and hope for the best
        push @TidyAddresses, $Str;
    }

    return \@TidyAddresses;

}

=helper_method I<get_my_hostname()>

Return the effective hostname of the MTA.

=cut

sub get_my_hostname {
    my ($self) = @_;
    my $hostname = $self->get_symbol('j');
    if ( ! $hostname ) {
        $hostname = $self->get_symbol('{rcpt_host}');
    }
    if ( ! $hostname ) { # Fallback
        $hostname = hostname;
    }
    return $hostname;
}



# Logging

=log_method I<dbgout( $key, $value, $priority )>

Send output to debug and/or Mail Log.

priority is a standard Syslog priority.

=cut

sub dbgout {
    my ( $self, $key, $value, $priority ) = @_;
    my $queue_id = $self->get_symbol('i') || q{--};
    $key   = q{--} if ! defined $key;
    $value = q{--} if ! defined $value;

    my $config = $self->config();
    if (
        $priority == LOG_DEBUG
        &&
        ! $config->{'debug'}
    ) {
        return;
    }

    if ( $config->{'logtoerr'} ) {
        Mail::Milter::Authentication::_warn( "$queue_id: $key: $value" );
    }

    my $top_handler = $self->get_top_handler();
    if ( !exists( $top_handler->{'dbgout'} ) ) {
        $top_handler->{'dbgout'} = [];
    }
    push @{ $top_handler->{'dbgout'} },
      {
        'priority' => $priority || LOG_INFO,
        'key'      => $key      || q{},
        'value'    => $value    || q{},
      };

    # Write now if we can.
    if ( $self->get_symbol('i') ) {
        $self->dbgoutwrite();
    }

    return;
}

=log_method I<log_error( $error )>

Log an error.

=cut

sub log_error {
    my ( $self, $error ) = @_;
    $self->dbgout( 'ERROR', $error, LOG_ERR );
    return;
}

=log_method I<dbgoutwrite()>

Write out logs to disc.

Logs are not written immediately, they are written at the end of a connection so we can
include a queue id. This is not available at the start of the process.

=cut

sub dbgoutwrite {
    my ($self) = @_;
    eval {
        my $config = $self->config();
        my $queue_id = $self->get_symbol('i') ||
            'NOQUEUE.' . substr( uc md5_hex( "Authentication Milter Client $PID " . time() . rand(100) ) , -11 );
        my $top_handler = $self->get_top_handler();
        if ( exists( $top_handler->{'dbgout'} ) ) {
            LOGENTRY:
            foreach my $entry ( @{ $top_handler->{'dbgout'} } ) {
                my $key      = $entry->{'key'};
                my $value    = $entry->{'value'};
                my $priority = $entry->{'priority'};
                my $line     = "$queue_id: $key: $value";
                if (
                    $priority == LOG_DEBUG
                    &&
                    ! $config->{'debug'}
                ) {
                    next LOGENTRY;
                }
                syslog( $priority, $line );
            }
        }
        delete $top_handler->{'dbgout'};
    };
    $self->handle_exception( $@ );  # Not usually called within an eval, however we shouldn't
                                    # ever get a Timeout (for example) here, so it is safe to
                                    # pass to handle_exception anyway.
    return;
}



# Header handling

=method I<can_sort_header( $header )>

Returns 1 is this handler has a header_sort method capable or sorting entries for $header
Returns 0 otherwise

=cut

sub can_sort_header {
    my ( $self, $header ) = @_;
    return 0;
}

=method I<header_sort()>

Sorting function for sorting the Authentication-Results headers
Calls out to __HANDLER__->header_sort() to sort headers of a particular type if available,
otherwise sorts alphabetically.

=cut

sub header_sort {
    my ( $self, $sa, $sb ) = @_;

    my $config = $self->config();

    my $string_a;
    my $string_b;

    my $handler_a;
    if ( ref $sa eq 'Mail::AuthenticationResults::Header::Entry' ) {
        $handler_a = $sa->key();
        $string_a = $sa->as_string();
    }
    else {
        ( $handler_a ) = split( '=', $sa, 2 );
        $string_a = $sa;
    }
    my $handler_b;
    if ( ref $sb eq 'Mail::AuthenticationResults::Header::Entry' ) {
        $handler_b = $sb->key();
        $string_b = $sb->as_string();
    }
    else {
        ( $handler_b ) = split( '=', $sb, 2 );
        $string_b = $sb;
    }

    if ( $handler_a eq $handler_b ) {
        # Check for a handler specific sort method
        foreach my $name ( @{$config->{'load_handlers'}} ) {
            my $handler = $self->get_handler($name);
            if ( $handler->can_sort_header( lc $handler_a ) ) {
                if ( $handler->can( 'handler_header_sort' ) ) {
                    return $handler->handler_header_sort( $sa, $sb );
                }
            }
        }
    }

    return $string_a cmp $string_b;
}

sub _stringify_header {
    my ( $self, $header ) = @_;
    if ( ref $header eq 'Mail::AuthenticationResults::Header::Entry' ) {
        return $header->as_string();
    }
    return $header;
}

=method I<add_headers()>

Send the header changes to the MTA.

=cut

sub add_headers {
    my ($self) = @_;

    my $config = $self->config();

    my $header = $self->get_my_hostname();
    my $top_handler = $self->get_top_handler();

    my @auth_headers;
    if ( exists( $top_handler->{'c_auth_headers'} ) ) {
        @auth_headers = @{ $top_handler->{'c_auth_headers'} };
    }
    if ( exists( $top_handler->{'auth_headers'} ) ) {
        @auth_headers = ( @auth_headers, @{ $top_handler->{'auth_headers'} } );
    }
    if (@auth_headers) {

        @auth_headers = sort { $self->header_sort( $a, $b ) } @auth_headers;

        # Do we have any legacy type headers?
        my $are_string_headers = 0;
        my $header_obj = Mail::AuthenticationResults::Header->new();
        foreach my $header ( @auth_headers ) {
            if ( ref $header ne 'Mail::AuthenticationResults::Header::Entry' ) {
                $are_string_headers = 1;
                last;
            }
            $header_obj->add_child( $header );
        }

        if ( $are_string_headers ) {
            # We have legacy headers, add in a legacy way
            $header .= ";\n    ";
            $header .= join( ";\n    ", map { $self->_stringify_header( $_ ) } @auth_headers );
        }
        else {
            $header_obj->set_value( Mail::AuthenticationResults::Header::AuthServID->new()->safe_set_value( $self->get_my_hostname() ) );
            $header_obj->set_eol( "\n" );
            if ( exists( $config->{'header_indent_style'} ) ) {
                $header_obj->set_indent_style( $config->{'header_indent_style'} );
            }
            else {
                $header_obj->set_indent_style( 'entry' );
            }
            if ( exists( $config->{'header_indent_by'} ) ) {
                $header_obj->set_indent_by( $config->{'header_indent_by'} );
            }
            else {
                $header_obj->set_indent_by( 4 );
            }
            if ( exists( $config->{'header_fold_at'} ) ) {
                $header_obj->set_fold_at( $config->{'header_fold_at'} );
            }
            $header = $header_obj->as_string();
        }

    }
    else {
        $header .= '; none';
    }

    $self->prepend_header( 'Authentication-Results', $header );

    if ( my $reason = $self->get_quarantine_mail() ) {
        $self->prepend_header( 'X-Disposition-Quarantine', $reason );
    }

    $top_handler->top_addheader_callback();

    if ( exists( $top_handler->{'pre_headers'} ) ) {
        foreach my $header ( @{ $top_handler->{'pre_headers'} } ) {
            $self->dbgout( 'PreHeader',
                $header->{'field'} . ': ' . $header->{'value'}, LOG_INFO );
            $self->insert_header( 1, $header->{'field'}, $header->{'value'} );
        }
    }

    if ( exists( $top_handler->{'add_headers'} ) ) {
        foreach my $header ( @{ $top_handler->{'add_headers'} } ) {
            $self->dbgout( 'AddHeader',
                $header->{'field'} . ': ' . $header->{'value'}, LOG_INFO );
            $self->add_header( $header->{'field'}, $header->{'value'} );
        }
    }

    return;
}

=method I<prepend_header( $field, $value )>

Add a trace header to the email.

=cut

sub prepend_header {
    my ( $self, $field, $value ) = @_;
    my $top_handler = $self->get_top_handler();
    if ( !exists( $top_handler->{'pre_headers'} ) ) {
        $top_handler->{'pre_headers'} = [];
    }
    push @{ $top_handler->{'pre_headers'} },
      {
        'field' => $field,
        'value' => $value,
      };
    return;
}

=method I<add_auth_header( $value )>

Add a section to the authentication header for this email.

=cut

sub add_auth_header {
    my ( $self, $value ) = @_;
    my $top_handler = $self->get_top_handler();
    if ( !exists( $top_handler->{'auth_headers'} ) ) {
        $top_handler->{'auth_headers'} = [];
    }
    push @{ $top_handler->{'auth_headers'} }, $value;
    return;
}

=method I<add_c_auth_header( $value )>

Add a section to the authentication header for this email, and to any subsequent emails for this connection.

=cut

sub add_c_auth_header {

    # Connection wide auth headers
    my ( $self, $value ) = @_;
    my $top_handler = $self->get_top_handler();
    if ( !exists( $top_handler->{'c_auth_headers'} ) ) {
        $top_handler->{'c_auth_headers'} = [];
    }
    push @{ $top_handler->{'c_auth_headers'} }, $value;
    return;
}

=method I<append_header( $field, $value )>

Add a normal header to the email.

=cut

sub append_header {
    my ( $self, $field, $value ) = @_;
    my $top_handler = $self->get_top_handler();
    if ( !exists( $top_handler->{'add_headers'} ) ) {
        $top_handler->{'add_headers'} = [];
    }
    push @{ $top_handler->{'add_headers'} },
      {
        'field' => $field,
        'value' => $value,
      };
    return;
}



# Lower level methods

=low_method I<smfis_continue()>

Return Continue code.

=cut

sub smfis_continue {
    return SMFIS_CONTINUE;
}

=low_method I<smfis_tempfail()>

Return TempFail code.

=cut

sub smfis_tempfail {
    return SMFIS_TEMPFAIL;
}

=low_method I<smfis_reject()>

Return Reject code.

=cut

sub smfis_reject {
    return SMFIS_REJECT;
}

=low_method I<smfis_discard()>

Return Discard code.

=cut

sub smfis_discard {
    return SMFIS_DISCARD;
}

=low_method I<smfis_accept()>

Return Accept code.

=cut

sub smfis_accept {
    return SMFIS_ACCEPT;
}



=low_method I<write_packet( $type, $data )>

Write a packet to the MTA (calls Protocol object)

=cut

sub write_packet {
    my ( $self, $type, $data ) = @_;
    my $thischild = $self->{'thischild'};
    $thischild->write_packet( $type, $data );
    return;
}

=low_method I<add_header( $key, $value )>

Write an Add Header packet to the MTA (calls Protocol object)

=cut

sub add_header {
    my ( $self, $key, $value ) = @_;
    my $thischild = $self->{'thischild'};
    my $config = $self->config();
    return if $config->{'dryrun'};
    $thischild->add_header( $key, $value );
    return;
}

=low_method I<insert_header( $index, $key, $value )>

Write an Insert Header packet to the MTA (calls Protocol object)

=cut

sub insert_header {
    my ( $self, $index, $key, $value ) = @_;
    my $thischild = $self->{'thischild'};
    my $config = $self->config();
    return if $config->{'dryrun'};
    $thischild->insert_header( $index, $key, $value );
    return;
}

=low_method I<change_header( $key, $index, $value )>

Write a Change Header packet to the MTA (calls Protocol object)

=cut

sub change_header {
    my ( $self, $key, $index, $value ) = @_;
    my $thischild = $self->{'thischild'};
    my $config = $self->config();
    return if $config->{'dryrun'};
    $thischild->change_header( $key, $index, $value );
    return;
}

1;

__END__

=head1 WRITING HANDLERS

tbc

