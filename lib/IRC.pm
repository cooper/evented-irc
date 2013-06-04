#---------------------------------------------------
# libirc: an insanely flexible perl IRC library.   |
# ntirc: an insanely flexible IRC client.          |
# foxy: an insanely flexible IRC bot.              |
# Copyright (c) 2012, the NoTrollPlzNet developers |
# Copyright (c) 2012-13, Mitchell Cooper           |
#---------------------------------------------------
package IRC;

# TODO LIST:
#
#   [ ] use a consistent structure for storing ircd-related information in an IRC object
#   [ ] make methods to fetch server capability information from RPL_ISUPPORT
#   [ ] make preset channel status levels for voice and halfop
#   [ ] create a class for manging multiple IRC servers
#   [ ] make users and channels independent of IRC objects with ->add_*, ->remove_*, etc.
#

use warnings;
use strict;
use utf8;
use 5.010;
use parent qw(EventedObject IRC::Functions::IRC);
use overload
    '""'     => sub { shift->{id} },            # string context  = ID
    '0+'     => sub { shift },                  # numeric context = memory address 
    'bool'   => sub { 1 },                      # boolean context = true
    '${}'    => sub { \shift->{network} },      # scalar deref    = network name
    '~~'     => \&_match,                       # smart matching
    fallback => 1;


use EventedObject;

use Scalar::Util qw(blessed weaken);

use IRC::Pool;
use IRC::User;
use IRC::Channel;
use IRC::Handlers;
use IRC::Utils;
use IRC::Functions::IRC;
use IRC::Functions::User;
use IRC::Functions::Channel;

our $VERSION = '2.9';

# create a new IRC instance
sub new {
    my ($class, %opts) = @_;
    
    bless my $irc = {}, $class;
    configure($irc, %opts);
    
    return $irc;
}

# configure the IRC object.
sub configure {
    my ($irc, %opts) = @_;
    state $c = 0;
    
    # apply default handlers.
    if (!$irc->{_applied_handlers}) {
        $irc->IRC::Handlers::apply_handlers();
        $irc->{_applied_handlers} = 1;
        
        $irc->{id} = $c++.q(irc);
    }

    # create pool and own object.
    $irc->{pool} ||= IRC::Pool->new(irc  => $irc);
    $irc->{me}   ||= IRC::User->new(nick => $opts{nick});
    $irc->pool->add_user($irc->{me});
    $irc->pool->retain($irc->{me}, 'me:is_me');

    # Do we need SASL?
    if ($opts{sasl_user} && defined $opts{sasl_pass} && !$INC{'MIME/Base64.pm'}) {
        require MIME::Base64;
    }
    
}

##############################
### HANDLING INCOMING DATA ###
##############################

# DEPRECATED: parse a raw piece of IRC data.
# this has been replaced by handle_data() and parse_data_new()
# and remains here temporarily for compatibility only.
sub parse_data {
    my ($irc, $data) = @_;
    $irc->handle_data($data);
    
    $data =~ s/\0|\r//g; # remove unwanted characters

    # parse one line at a time
    if ($data =~ m/\n/) {
        $irc->parse_data($_) foreach split "\n", $data;
        return
    }

    my @args = split /\s/, $data;
    return unless defined $args[0];

    if ($args[0] eq 'PING') {
        $irc->send("PONG $args[1]");
    }

    # if there is no parameter, there's nothing to parse.
    return unless defined $args[1];

    my $command = lc $args[1];

    # fire the raw_* event (several of which fire more events from there on)
    $irc->fire_event("raw_$command", $data, @args);
    $irc->fire_event(raw => $data, @args); # for anything

}

# handle a piece of incoming data.
sub handle_data {
    my ($irc, $data) = @_;
    
    # strip unwanted characters
    $data =~ s/\0|\r//g;
    
    # parse each line, one at a time.
    if ($data =~ m/\n/) {
        $irc->handle_data($_) foreach split "\n", $data;
        return;
    }
    
    # parse the data.
    my ($source, $command, @args) = $irc->parse_data_new($data);
    $command = lc $command;
    
    #$irc->fire_event(raw => $data, split(/\s/, $data)); # for anything
    $irc->fire_event("scmd_$command" => $source, @args) if $source->{type} eq 'none';
    $irc->fire_event("cmd_$command"  => $source, @args) if $source->{type} ne 'none';
}

# parse a piece of incoming data.
sub parse_data_new {
    my ($irc, $data) = @_;    
    my ($arg_i, $char_i, $got_colon, $last_char, $source, @args) = (0, -1);
    
    # separate the arguments.
    
    foreach my $char (split //, $data) {
        $char_i++;
        
        # whitespace:
        # if the last character is not whitespace
        # and we have not received the colon.
        if ($char =~ m/\s/ && !$got_colon) { 
            next if $last_char =~ m/\s/;
            $arg_i++;
            $last_char = $char;
            next;
        }
        
        # colon:
        # if we haven't already received a colon
        # and this isn't the first character (that would be a source)
        # and we're not in the middle of an argument
        if ($char eq ':' && !$got_colon && $char_i && !length $args[$arg_i]) {
            $got_colon = 1;
            $last_char = $char;
            next;
        }
        
        # any other character.
        defined $args[$arg_i] or $args[$arg_i] = '';
        $args[$arg_i] .= $char;
        
        $last_char = $char;
    }
    
    # determine the source.
    
    # if it doesn't start with a colon, no source.
    if ($args[0] !~ m/^:/) {
        $source = { type => 'none' };
    }
    
    # it's a user.
    elsif ($args[0] =~ m/^:(.+)!(.+)@(.+)/) {
        shift @args;
        $source = {
            type => 'user',
            nick => $1,
            user => $2,
            host => $3
        };
    }
    
    # it must be a server.
    elsif ($args[0] =~ m/^:(.+)/) {
        shift @args;
        $source = {
            type => 'server',
            name => $1
        };
    }
    
    return ($source, @args);
}

# handling arguments.
sub args {
    my @types = split /\s/, pop;
    my ($irc, $event, $i, $u, @args, @return, @modifiers) = __PACKAGE__;
    
    # filter out IRC objects and event fire objects.
    ARG: foreach my $arg (@_) {
        if (blessed $arg) {
        
            # IRC object.
            $irc = $arg if $arg->isa('IRC');
            
            # event object.
            if ($arg->isa('EventedObject::EventFire')) {
                $irc   = $arg->object if !$irc;
                $event = $arg;
            }

            next ARG;
        }
        
        # any other argument.
        push @args, $arg;
        
    }
    
    # type aliases.
    state $aliases = {
        target => 'channel|user',
        event  => 'fire',
        '@'    => 'list'
    };
    
    # filter modifiers.
    $u = 0;
    foreach my $ustr (@types) {
        $ustr =~ m/^([\.\+]*)(.+)$/;
        $modifiers[$u] = $1 ? [split //, $1] : [];
        $types[$u]     = exists $aliases->{$2} ? $aliases->{$2} : $2;
        $u++;
    }
    
    ($i, $u) = (-1, -1);
    
    my $return;                # irc   ustr
    USTR: foreach (@types)     { $i++; $u++;    # type string w/o modifiers (i.e. 'user,channel')
    
        my $arg  = $args[$i];
        my @mods = @{$modifiers[$u]};
        
    TYPE: foreach (split /\|/) {                # individual type string (i.e. 'user')
        my $type = $_;
        
        # we already found a return value for this ustr.
        last TYPE if defined $return;
        
        # dummy modifier; skip.
        next USTR if '.' ~~ @mods;
        
        # IRC object.
        when ('irc') {
            $return = $irc;
            $i--; # these are not actually IRC arguments.
        }
        
        # event fire object.
        when ('fire') {
            $return = $event;
            $i--; # these are not actually IRC arguments.
        }
        
        # server or user.
        when ('source') {
        
            # if the argument is a hash reference, it's a source ref.
            if (ref $arg && ref $arg eq 'HASH') {
                $return = $irc->_get_source($arg);
                next TYPE;
            }
        
            # check for a user string.
            if ($arg =~ m/^:*(.+)!(.+)\@(.+)/) {
                my ($nick, $ident, $host) = ($1, $2, $3);
                $return = $irc->_get_source({
                    type => 'user',
                    nick => $nick,
                    user => $ident,
                    host => $host
                });
                next TYPE;
            }
            
            # TODO: servers.
            
        }
        
        # user source, id, or nickname.
        when ('user') {
        
            # is it a source object?
            if (ref $arg && ref $arg eq 'HASH') {
                my $source = $irc->_get_source($arg);
                $return = $source, next TYPE if $source;
            }
            
            # nickname or ID.
            $return = $irc->pool->get_user($arg);
            
        }
        
        # channel id or name.
        when ('channel') {
            $return = $irc->pool->get_channel($arg);
        }
        
        # any string.
        when ('*') {
            $return = $arg;
        }
        
        # space-separated list.
        # this assumes all remaining arguments are part of the list.
        when ('list') {
            push @return, map { split /\s/ } @args[$i..$#args];
            next USTR;
        }
        
        # the rest of the arguments.
        when ('rest') {
            push @return, @args[$i..$#args];
            next USTR;
        }
        
        # dummy.
        when ('.') {
            # do nothing.
            next USTR;
        }
        
    }
        # if the + modifier is present, this value MUST be defined.
        if ('+' ~~ @mods && !defined $return) {
            return;
        }
        
        push @return, $return; $return = undef
    
    }
    
    return @return;
}

# fetch a source from a source ref.
sub _get_source {
    my ($irc, $source) = @_;
    return if not $source && ref $source eq 'HASH';
    if ($source->{type} eq 'user') {
        my $user = $irc->new_user_from_nick($source->{nick});
        return unless $user;
        
        # update host.
        $user->set_host($source->{host})
            if !length $user->{host} || $source->{host} ne $user->{host};
            
        # update user.
        $user->set_user($source->{user})
            if !length $user->{user} || $source->{user} ne $user->{user};    
            
        return $user;    
    }
    return 'fakeserver'; # TODO: servers.
    return;
}

#############################
### SENDING OUTGOING DATA ###
#############################

# send data.
sub send {
    my ($irc, $data) = @_;
    $irc->fire_event(send => $data);
}

# send login information.
sub login {
    my $irc = shift;
    
    my ($nick, $ident, $real, $pass) = (
        $irc->{nick}, 
        $irc->{user},
        $irc->{real},
        $irc->{pass}
    );
    
    # request capabilities.
    $irc->send('CAP LS');
    
    # send login information.
    $irc->send("PASS $pass") if defined $pass && length $pass;
    $irc->send("NICK $nick");
    $irc->send("USER $ident * * :$real");
    
    # SASL authentication.
    if ($irc->{sasl_user} && defined $irc->{sasl_pass}) {
        $irc->cap_request('sasl');
    }
    
    $irc->_check_login;
    
}

###################################
### FETCHING USERS AND CHANNELS ###
###################################

# return a channel from its name
sub channel_from_name {
    my ($irc, $name) = @_;
    return $irc->pool->get_channel($name);
}

# create a new channel by its name
# or return the channel if it exists
sub new_channel_from_name {
    my ($irc, $name) = @_;
    return $irc->pool->get_channel($name)
    || $irc->pool->add_channel( IRC::Channel->new(
        pool => $irc->pool,
        name => $name
    ) );
}

# create a new user by his nick
# or return the user if it exists
sub new_user_from_nick {
    my ($irc, $nick) = @_;
    return $irc->user_from_nick($nick)
    || $irc->pool->add_user( IRC::User->new(
        pool => $irc->pool,
        nick => $nick
    ) );
}

# return a user by his nick
sub user_from_nick {
    my ($irc, $nick) = @_;
    return $irc->pool->get_user($nick);
}

# create a new user by his :nick!ident@host string
# or return the user if it exists
sub new_user_from_string {
    my ($irc, $user_string) = @_;
    $user_string =~ m/^:*(.+)!(.+)\@(.+)/ or return;
    my ($nick, $ident, $host) = ($1, $2, $3);
    return $irc->user_from_string($user_string)
    || $irc->pool->add_user( IRC::User->new(nick => $nick) );
        
    # TODO: host/ident change.
    
}

# return a user by his :nick!ident@host string
sub user_from_string {
    my ($irc, $user_string) = @_;
    $user_string =~ m/^:*(.+)!(.+)\@(.+)/ or return;
    my ($nick, $ident, $host) = ($1, $2, $3);

    # find the user.
    my $user = $irc->pool->get_user($nick);
    
    # TODO: host/ident change.

    return $user;
}

##########################
### IRCv3 CAPABILITIES ###
##########################

# determine if the ircd we're connected to suppots a particular capability.
sub has_cap {
    my ($irc, $cap) = @_;
    return $irc->{ircd}->{capab}->{lc $cap};
}

# determine if we have told the server we want a CAP, and the server is okay with it.
sub cap_enabled {
    my ($irc, $cap) = @_;
    return $irc->{active_capab}->{lc $cap};
}

sub cap_request {
    my ($irc, $cap) = @_;
    $irc->retain_login;
    $irc->send("CAP REQ $cap");
    $irc->{pending_cap} ||= [];
    push @{ $irc->{pending_cap} }, $cap;
}

# add a wait during login.
sub retain_login {
    my $irc = shift;
    $irc->{login_refcount} ||= 0;
    $irc->{login_refcount}++;
    $irc->_check_login;
    return $irc->{login_refcount};
}

# release a wait during login.
sub release_login {
    my $irc = shift;
    $irc->{login_refcount} ||= 0;
    $irc->_check_login;
    return $irc->{login_refcount};
}

# internal: check if CAP negotiation is complete.
sub _check_login {
    my $irc = shift;
    $irc->send('CAP END') if !$irc->{login_refcount};
}

#########################
### INTERNAL ROUTINES ###
#########################

# smart matching
sub _match {
    my ($irc, $other) = @_;
    
    # anything that is not blessed is a no no.
    return unless blessed $other;
    
    # anything else, check if it belongs to this IRC object.
    return ($other->can('irc') ? $other->irc : $other->{irc} or -1) == $irc;
    
}


# fetchers.

sub id   { shift->{id}   }
sub pool { shift->{pool} }

1
