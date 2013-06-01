#---------------------------------------------------
# libirc: an insanely flexible perl IRC library.   |
# ntirc: an insanely flexible IRC client.          |
# foxy: an insanely flexible IRC bot.              |
# Copyright (c) 2011, the NoTrollPlzNet developers |
# Copyright (c) 2012-12, Mitchell Cooper           |
# User.pm: the user object class.                  |
#---------------------------------------------------
package IRC::User;

use warnings;
use strict;
use parent qw(EventedObject IRC::Functions::User);
use 5.010;

use overload
    '""'     => sub { shift->{id} },            # string context  = ID
    '0+'     => sub { shift },                  # numeric context = memory address 
    'bool'   => sub { 1 },                      # boolean context = true
    '${}'    => sub { \shift->{nick} },         # scalar deref    = nickname
    '~~'     => sub { $_[1]->has_user($_[0]) }, # smart match     = user in channel
    fallback => 1;

use Scalar::Util 'weaken';

#####################
### CLASS METHODS ###
#####################

sub new {
    my ($class, $irc, $nick) = @_;
    $nick ||= 'libirc';

    # create a new user object
    $irc->{users}{lc $nick} = bless my $user = {
        nick     => $nick,
        events   => {},
        id       => $irc->_next_user_id,
        channels => {}
    }, $class;

    # reference weakly to the IRC object.
    $user->{irc} = $irc;
    weaken($user->{irc});
    
    # make the IRC object a listener.
    $user->add_listener($irc, 'user');

    # fire new user event
    $user->fire_event(new => $user);

    return $user;
}

# parses a :nick!ident@host
# and finds the user
sub from_string {
    my ($irc, $user_string) = @_;
    $user_string =~ m/^:(.+)!(.+)\@(.+)/ or return;
    my ($nick, $ident, $host) = ($1, $2, $3);

    # find the user, set the info
    my $user = $irc->{users}->{lc $nick} or return; # or give up

    if (defined $user) {
        my $old_ident = $user->{user};
        my $old_host  = $user->{host};

        # fire changed events
        if ($old_ident ne $ident) {
            $user->{user} = $ident;
            $user->fire_event(user_change => $old_ident, $ident);
        }
        if ($old_host ne $host) {
            $user->{host} = $host;
            $user->fire_event(host_change => $old_host, $host);
        }
    }

    return $user
}

# parses a :nick!ident@host
# and creates a new user if it doesn't exist
# finds it if it does
sub new_from_string {
    my ($package, $irc, $user_string) = @_;
    $user_string =~ m/^:(.+)!(.+)\@(.+)/ or return;
    my ($nick, $ident, $host) = ($1, $2, $3);

    # find the user, set the info
    my $user = defined $irc->{users}->{lc $nick} ? $irc->{users}->{lc $nick} : $package->new($irc, $nick); # or create a new one

    if (defined $user) {
        $user->{user} = $ident;
        $user->{host} = $host;
    }

    return $user
}

# find a user by his nick
sub from_nick {
    my ($irc, $nick) = (shift, lc shift);
    exists $irc->{users}->{$nick} ? $irc->{users}->{$nick} : undef
}

# find a user by his nick
# or create one if it doesn't exist
sub new_from_nick {
    my ($package, $irc, $nick) = @_;

    if (exists $irc->{users}->{lc $nick}) {
        return $irc->{users}->{lc $nick}
    }

    return $irc->{users}->{lc $nick} = $package->new($irc, $nick)
}

########################
### INSTANCE METHODS ###
########################

# change the nickname and move the object's location
sub set_nick {
    my ($user, $newnick) = @_;
    my $irc = $user->{irc};

    delete $irc->{users}->{lc $user->{nick}};

    my $oldnick                  = $user->{nick};
    $user->{nick}                = $newnick;
    $irc->{users}->{lc $newnick} = $user;

    # fire events
    $user->fire_event(nick_change => $oldnick, $newnick);
}


# returns a list of channels the user is on
sub channels {
    return values %{ shift->{channels} };
}

# in a common channel with..
sub in_common {
    my ($user, $other_user) = @_;
    foreach my $channel ($user->channels) {
        return 1 if $channel->has_user($other_user)
    }
    return
}

# set account name
sub set_account {
    my ($user, $account) = @_;
    $user->{account} = $account;
}

sub id { shift->{id} }

1
