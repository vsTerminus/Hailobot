#!/usr/bin/env perl

use v5.10;
use strict;
use warnings;

use Hailo;
use Net::Discord;
use Net::Twitter;
use Config::Tiny;
use Mojo::IOLoop;

# Fallback to "config.ini" if the user does not pass in a config file.
my $config_file = $ARGV[0] // 'config.ini';
my $config = Config::Tiny->read($config_file, 'utf8');
say localtime(time) . " - Loaded Config: $config_file";

# Create the Hailo Object
my $hailo = Hailo->new({'brain' => $config->{'hailo'}->{'brain_file'}});

#######################
#
#   Twitter
#
#######################

my $twitter;
my $last_check = time;

if ( $config->{'twitter'}->{'use_twitter'} )
{
    say localtime(time) . " - Using Twitter." if $config->{'twitter'}->{'verbose'};

    $twitter = Net::Twitter->new(
        traits              => [qw/OAuth API::RESTv1_1/],
        consumer_key        => $config->{'twitter'}->{'consumer_key'},
        consumer_secret     => $config->{'twitter'}->{'consumer_secret'},
        access_token        => $config->{'twitter'}->{'access_token'},
        access_token_secret => $config->{'twitter'}->{'access_secret'},
        ssl                 => 1,   # Use encryption
    );

    # If we are configured to poll for new tweets, set that up now.
    if ( $config->{'twitter'}->{'poll_interval'} )
    {
        Mojo::IOLoop->recurring($config->{'twitter'}->{'poll_interval'} => sub { read_tweets() });
    }

    # If we are configured for periodic random tweets, set that up now.
    if ( $config->{'twitter'}->{'tweet_interval'} )
    {
        Mojo::IOLoop->recurring($config->{'twitter'}->{'tweet_interval'} => sub { send_tweet() });
    }
}

sub read_tweets
{
    my $mentions = $twitter->mentions({ 'since' => $last_check });
    $last_check = time;

    say localtime(time) . " - Checking for mentions..." if $config->{'twitter'}->{'verbose'};

    foreach my $tweet (@{$mentions})
    {       
        say localtime(time) . " - Mentioned by ". $tweet->{user}{screen_name} .": " . $tweet->{text};
        my $user = $tweet->{user}{screen_name};
        my $text = $tweet->{text};

        # Only reply to tweets that begin with the bot's name.
        my $my_username = $config->{'twitter'}->{'name'};
        if ( $text =~ /^\@$my_username /i )
        {
            say localtime(time) . " - Generating a reply to \@$user" if $config->{'twitter'}->{'verbose'};
            my $reply_to = $tweet->{id_str};
            my $reply = "";
            
            # Strip my name out of the tweet.
            $text =~ s/^\@$my_username //i;

            # Generate a suitable response
            # Twitter's max length is 140, but we're going to put @ in front and a space behind the name, so our max is 138 minus the length of the username
            my $max_length = 138 - length $user;

            $reply = "\@$user " . generate_tweet($max_length, $text);

            $twitter->update($reply, {in_reply_to_status_id => $reply_to}) if length $reply;
        }
        # Else: We were mentioned, but not at the beginning of the line, so we're going to ignore it.
    }
}

sub send_tweet
{
    my ($message, $reply_to) = @_;
    my $result;

    $message = generate_tweet(140) unless defined($message);

    $result = eval 
    {
        $result = defined $reply_to ? $twitter->update($message, {in_reply_to_status_id => $reply_to}) : $twitter->update($message);
    };

    say localtime(time) . " - Sent tweet: $message";
    
    say $@ if $@;

    return $result;
}

# This generates a length-restricted message for twitter
sub generate_tweet
{
    my ($max_length, $message) = @_;

    my $reply = "";

    # Try at most 10 times to generate a suitable response.
    for( my $i = 0; $i < 10 and (length $reply < 1 or length $reply > $max_length); $i++ )
    {
        $reply = defined $message ? $hailo->reply($message) : $hailo->reply();
    }

    if ( length $reply > $max_length )
    {
        say localtime(time) . " - Failed to generate suitable reply. Truncated to $max_length characters." if $config->{'twitter'}->{'verbose'};
        $reply = substr($reply, 0, $max_length) if length $reply > $max_length;
    }
    
    return $reply;
}

#######################
#
#   Discord
#
#######################

my $discord_name;
my $discord_id;

say localtime(time) . " - Using Discord." if $config->{'discord'}->{'use_discord'} and $config->{'discord'}->{'verbose'};

my $discord = Net::Discord->new(
    'token'     => $config->{'discord'}->{'token'},
    'name'      => $config->{'discord'}->{'name'},
    'url'       => $config->{'discord'}->{'redirect_url'},
    'version'   => '1.0',
    'callbacks' => {
        'on_ready'          => \&discord_on_ready,
        'on_message_create' => \&discord_on_message_create,
    },
    'reconnect' => $config->{'discord'}->{'auto_reconnect'},
    'verbose'   => $config->{'discord'}->{'verbose'},
);

sub discord_on_ready
{
    my ($hash) = @_;

    $discord_name   = $hash->{'user'}{'username'};
    $discord_id     = $hash->{'user'}{'id'};
    
    $discord->status_update({'game' => 'Hailo'});

    say localtime(time) . " - Connected to Discord.";
};

sub discord_on_message_create
{
    my $hash = shift;

    my $author = $hash->{'author'};
    my $msg = $hash->{'content'};
    my $channel = $hash->{'channel_id'};
    my @mentions = @{$hash->{'mentions'}};

    foreach my $mention (@mentions)
    {
        my $id = $mention->{'id'};
        my $username = $mention->{'username'};

        # Replace the mention IDs in the message body with the usernames.
        $msg =~ s/\<\@$id\>/$username/;
    }

    if ( $msg =~ /^$discord_name/i )
    {
        $msg =~ s/^$discord_name.? ?//i;   # Remove the username. Can I do this as part of the if statement?

        $discord->start_typing($channel); # Tell the channel we're thinking about a response
        my $reply = $hailo->reply($msg);    # Sometimes this takes a while.
        $discord->send_message( $channel, $reply ); # Send the response.
    
    }

}

if ( $config->{'discord'}->{'use_discord'} )
{
    # Establish the websocket and start the listener.
    # This really should be the last line, because nothing below it will ever be executed.
    $discord->init();
}

# Start the IOLoop unless it is already running. 
# Since Discord also starts the IOLoop we will only get here if the bot is not using Discord.
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
