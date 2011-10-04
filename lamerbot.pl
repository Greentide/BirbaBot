#!/usr/bin/perl
# -*- mode: cperl -*-

# No copyright
# Written by Marco Pessotto a.k.a. MelmothX

# This code is free software; you may redistribute it
# and/or modify it under the same terms as Perl itself.

use strict;
use warnings;
use Data::Dumper;

my $config_file = $ARGV[0];
my $debug = $ARGV[1];

show_help() unless $config_file;

### configuration checking 

my $configuration = read_config($config_file);

print Dumper($configuration) if $debug;

my $nick = $configuration->{'nick'};
my $ircname = $configuration->{'ircname'};
my $server = $configuration->{'server'};

show_help("Missing configuration options\n") 
  unless ($configuration->{nick} and
	$configuration->{ircname} and 
	$configuration->{server});

my @channels = split(/ *, */, $configuration->{'channels'});


if ($debug) {
  print "Connecting to $server with nick $nick and ircname $ircname, ",
    "joining channels ", 
      join(" and ", @channels), "\n";
}

### starting POE stuff

use POE qw(Component::IRC);

my $irc = POE::Component::IRC->spawn(
				     # TODO: before using this
				     # directly would be better to
				     # clean it up, ok?
				     %$configuration
) or die "WTF? $!\n";

POE::Session->create(
		     package_states => [
					main => [qw(_default 
						    _start 
						    irc_001
						    irc_public)],
				       ],
		     heap => {irc => $irc},
		     );
$poe_kernel->run();


## just copy and pasted, ok?

sub _start {
    my $heap = $_[HEAP];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};

    $irc->yield( register => 'all' );
    $irc->yield( connect => { } );
    return;
}

sub irc_001 {
    my $sender = $_[SENDER];

    # Since this is an irc_* event, we can get the component's object by
    # accessing the heap of the sender. Then we register and connect to the
    # specified server.
    my $irc = $sender->get_heap();

    print "Connected to ", $irc->server_name(), "\n";

    # we join our channels
    $irc->yield( join => $_ ) for @channels;
    return;
}

sub irc_public {
    my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
        $rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
        $irc->yield( privmsg => $channel => "$nick: $rot13" );
    }
    return;
}

# We registered for all events, this will produce some debug info.
sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    for my $arg (@$args) {
        if ( ref $arg eq 'ARRAY' ) {
            push( @output, '[' . join(', ', @$arg ) . ']' );
        }
        else {
            push ( @output, "'$arg'" );
        }
    }
    print join ' ', @output, "\n";
    return 0;
}



exit;

=head2 read_config

Read the configuration file, which should be passed on the command
line, and return an hashref with key-value pairs for the bot config.

=cut 

sub read_config {
  my $file = shift;
  my %config;
  show_help() unless (-f $file);
  open (my $fh, "<", $file) or die "Cannot read $file $!\n";
  while (<$fh>) {
    my $line = $_;
    # strip whitespace
    chomp $line;
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    next if ($line =~ m/^#/);
    if ($line =~ m/(\w+)\s*=\s*(.*)/) {
      my $key = $1;
      my $value = $2;
      $value =~ s/^"//;
      $value =~ s/"$//;
      if ($key && $value) {
	$config{$key} = $value;
      }
    }
  }
  close $fh;
  return \%config;
}

=head2 show_help

Well, show the help and exit

=cut


sub show_help {
  my $string = shift;
  print "$string\n" if $string;

  print <<HELP;


This script runs the bot. It takes a mandatory argument with the
configuration file. The configuration file have values like this:

nick = pippo_il_bot
server = irc.syrolnet.org

Blank lines are just ignored. Lines starting with # are ignored too.
Don't put comments on the same line of a key-value pair, OK?
(Otherwise the comment will become part of the value).

Good luck.

HELP
  exit 1;
}
