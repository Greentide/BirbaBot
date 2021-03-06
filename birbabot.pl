#!/usr/bin/perl
# -*- mode: cperl -*-

# No copyright
# Written by Marco Pessotto a.k.a. MelmothX

# This code is free software; you may redistribute it
# and/or modify it under the same terms as Perl itself.

use strict;
use warnings;

use Cwd;
use LWP::Simple;
use File::Spec;
use File::Temp qw//;
use File::Copy;
use File::Path qw(make_path);
use Data::Dumper;
use File::Basename;
use lib './BirbaBot/lib';
use BirbaBot qw(create_bot_db
		read_config
		override_defaults show_help);
use BirbaBot::RSS qw(
		     rss_add_new
		     rss_delete_feed
		     rss_get_my_feeds
		     rss_give_latest
		     rss_list
		     rss_clean_unused_feeds
		   );
use BirbaBot::Geo;
use BirbaBot::Searches qw(search_google
			  query_meteo
			  yahoo_meteo
			  search_imdb
			  search_bash
			  search_urban
			  get_youtube_title
			);
use BirbaBot::Infos qw(kw_add kw_new kw_query kw_remove kw_list kw_find kw_show kw_delete_item karma_manage);
use BirbaBot::Todo  qw(todo_add todo_remove todo_list todo_rearrange);
use BirbaBot::Notes qw(notes_add notes_give notes_pending anotes_pending notes_del anotes_del);
use BirbaBot::Shorten qw(make_tiny_url);
use BirbaBot::Quotes qw(ircquote_add 
		    ircquote_del 
		    ircquote_rand 
		    ircquote_last 
		    ircquote_find
		    ircquote_num);
use BirbaBot::Tail qw(file_tail);
use BirbaBot::Debian qw(deb_pack_versions deb_pack_search);

use URI::Find;
use URI::Escape;

use HTML::Entities;
use HTML::Strip;

use POE;
use POE::Component::Client::DNS;
use POE::Component::IRC::Common qw(parse_user l_irc irc_to_utf8);
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::BotCommand;
use POE::Component::IRC::Plugin::CTCP;
use Storable;
use YAML::Any qw/LoadFile/;

our $VERSION = '1.8';

use constant {
  USER_DATE     => 0,
  USER_MSG      => 1,
  DATA_FILE     => 'seen',
  SAVE_INTERVAL => 20 * 60, # save state every 20 mins
};

my $seen = { };
$seen = retrieve(DATA_FILE) if -s DATA_FILE;

my @longurls;
my $urifinder = URI::Find->new( sub { # print "Found url: ", $_[1], "\n"; 
				      push @longurls, $_[1]; } );

$| = 1; # turn buffering off

my $lastpinged;

# before starting, create a pid file

open (my $fh, ">", "birba.pid");
print $fh $$;
close $fh;
undef $fh;

# initialize the db

my $reconnect_delay = 300;

my %serverconfig = (
		    'nick' => 'Birba',
		    'ircname' => "Birba the Bot",
		    'username' => 'birbabot',
		    'server' => 'localhost',
		    'localaddr' => undef,
		    'port' => 7000,
		    'usessl' => 1,
		    'useipv6' => undef,
		   );

my %botconfig = (
		 'channels' => ["#lamerbot"],
		 'botprefix' => "@",
		 'rsspolltime' => 600, # default to 10 minutes
		 'dbname' => "bot.db",
		 'admins' => [ 'nobody!nobody@nowhere' ],
		 'fuckers' => [ 'fucker1',' fucker2'],
		 'nspassword' => 'nopass',
		 'tail' => {},
		 'ignored_lines' => [],
		 'relay_source' => [],
		 'relay_dest' => [],
		 'twoways_relay' => [],
		 'msg_log' => [],
		 'kw_prefix' => '',
		);

my %debconfig = (
		'debrels' => [],
		);

# initialize the local storage
my $localdir = File::Spec->catdir('data','rss');
make_path($localdir) unless (-d $localdir);

my $config_file = $ARGV[0];
my $debug = $ARGV[1];

show_help() unless $config_file;

### configuration checking 
my ($botconf, $serverconf, $debconf) = LoadFile($config_file);
override_defaults(\%serverconfig, $serverconf);
override_defaults(\%botconfig, $botconf);
override_defaults(\%debconfig, $debconf);


print "Bot options: ", Dumper(\%botconfig),
  "Server options: ", Dumper(\%serverconfig),
  "Debian Releases: ", Dumper(\%debconfig);

my $dbname = $botconfig{'dbname'};
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname", "", "",
		       { AutoCommit => 1, 
			 # 'sqlite_unicode' => 1
		       });
$dbh->do('PRAGMA foreign_keys = ON;') or die "Can't operate on the DB\n";
undef $dbname;

my @channels = @{$botconfig{'channels'}};

# build the regexp of the admins
my @adminregexps = process_admin_list(@{$botconfig{'admins'}});

my @fuckers = @{$botconfig{'fuckers'}};

my $relay_source = $botconfig{'relay_source'};
my $relay_dest = $botconfig{'relay_dest'};
my $twoways_relay = $botconfig{'twoways_relay'};
my $msg_log = $botconfig{'msg_log'};
my $ircname = $serverconfig{'ircname'};

my $debian_relfiles_base = File::Spec->catdir(getcwd(), 'debs');

# when we start, we check if we have all the tables.  By no means this
# guarantees that the tables are correct. Devs, I'm looking at you
create_bot_db($dbh) or die "Errors while updating db tables";

# be sure that the feeds are in the channels we join
rss_clean_unused_feeds($dbh, \@channels);

my $starttime = time;

my $bbold = "\x{0002}";
my $ebold = "\x{000F}";

### starting POE stuff

my $irc = POE::Component::IRC::State->spawn(%serverconfig) 
  or die "WTF? $!\n";

my $dns = POE::Component::Client::DNS->spawn();

POE::Session->create(
    package_states => [
        main => [ qw(_start
		     _default
		     irc_001 
		     irc_notice
		     irc_disconnected
		     irc_error
		     irc_socketerr
		     irc_ping
		     irc_kick
		     irc_botcmd_anotes
		     irc_botcmd_pull
		     irc_botcmd_restart
		     irc_botcmd_free
		     irc_botcmd_uptime
		     irc_botcmd_isdown
		     irc_botcmd_wikiz
		     irc_botcmd_remind
		     irc_botcmd_version
		     irc_botcmd_choose
		     irc_botcmd_bash
		     irc_botcmd_urban
		     irc_botcmd_karma
		     irc_botcmd_math
		     irc_botcmd_seen
		     irc_botcmd_note
		     irc_botcmd_notes
		     irc_botcmd_todo
		     irc_botcmd_done
		     irc_botcmd_kw
		     irc_botcmd_slap
		     irc_botcmd_geoip
		     irc_botcmd_lookup
		     irc_botcmd_rss
		     irc_botcmd_g
		     irc_botcmd_gi
		     irc_botcmd_gv
		     irc_botcmd_gw
		     irc_botcmd_imdb
		     irc_botcmd_quote
		     irc_botcmd_meteo
		     irc_botcmd_deb
		     irc_botcmd_debsearch
		     irc_botcmd_op
		     irc_botcmd_deop
		     irc_botcmd_voice
		     irc_botcmd_devoice
		     irc_botcmd_k
		     irc_botcmd_kb
                     irc_botcmd_mode
		     irc_botcmd_topic
		     irc_botcmd_timebomb
		     irc_botcmd_cut
		     timebomb_start
		     timebomb_check
		     irc_botcmd_lremind
 		     irc_public
		     irc_msg
                    irc_join
                    irc_part
                    irc_quit
		    save
		    greetings_and_die
                    irc_ctcp_action
		     rss_sentinel
		     tail_sentinel
		     debget_sentinel
		     reminder_sentinel
		     reminder_del
		     dns_response) ],
    ],
);

$poe_kernel->run();

## just copy and pasted, ok?

sub _start {
    my ($kernel) = $_[KERNEL];
    $irc->plugin_add('BotCommand', 
		     POE::Component::IRC::Plugin::BotCommand->new(
								  Commands => {
            slap   => 'Takes one argument: a nickname to slap.',
            lookup => 'Query Internet name servers | Takes two arguments: a record type like MX, AAAA (optional), and a host.',
	    geoip => 'IP Geolocation | Takes one argument: an ip or a hostname to lookup.',
	    rss => 'Manage RSS subscriptions: RSS add <name> <url> - RSS del <name> - RSS show <name> - RSS list',
            g => 'Do a google search: Takes one or more arguments as search values.',
            gi => 'Do a search on google images.',
            gv => 'Do a search on google videos.',
            gw => 'Do a search on wikipedia by google',
            bash => 'Get a random quote from bash.org - Optionally accepts one number as argument: bash <number>',
            urban => 'Get definitions from the urban dictionary | "urban url <word>" asks for the url',
            karma => 'Get the karma of a user | karma  <nick>',
            math => 'Do simple math (* / % - +). Example: math 3 * 3',
            seen => 'Search for a user: seen <nick>',
            note => 'Send a note to a user: note <nick> <message>',
	    notes => 'Without arguments lists pending notes by current user | "notes del <nickname>" Deletes all pending notes from the current user to <nickname>',
            todo => 'add something to the channel TODO; todo [ add "foo" | rearrange | done #id ]',
            done => 'delete something from the channel TODO; done #id',
	    remind => 'Store an alarm for the current user, delayed by "x minutes" or by "xhxm hours and minutes" or by "xdxhxm days, hours and minutes" | remind [ <x> | <xhxm> | <xdxhxm> ] <message> , assuming "x" is a number',
            lremind => 'List active reminders in current channel',
	    wikiz => 'Performs a search on "laltrowiki" and retrieves urls matching given argument | wikiz <arg>',
            kw => 'Manage the keywords: [kw new] foo is bar | [kw new] "foo is bar" is yes, probably foo is bar | [kw add] foo is bar2/bar3 | [kw forget] foo | [kw delete] foo 2/3 | [kw list] | [kw show] foo | [kw find] foo (query only) - [key > nick] spits key to nick in channel; [key >> nick] privmsg nick with key; [key?] ask for key. For special keywords usage please read the doc/Factoids.txt help file',
	    meteo => 'Query the weather for location | meteo <city>',							       
            imdb => 'Query the Internet Movie Database (If you want to specify a year, put it at the end). Alternatively, takes one argument, an id or link, to fetch more data.',
	    quote => 'Manage the quotes: quote [ add <text> | del <number> | <number> | rand | last | find <argument> ]',
	    choose => 'Do a random guess | Takes 2 or more arguments: choose <choice1> <choice2> <choice#n>',
	    version => 'Show from which git branch we are running the bot. Do not use without git',
            isdown => 'Check whether a website is up or down | isdown <domain>',									       
	    uptime => 'Bot\'s uptime',
            deb => 'Query for versions of debian pakage | Usage: deb <package_name>',
            debsearch => 'Find packages matching <string> | debsearch <string>',									       
	    free => 'Show system memory usage',
            restart => 'Restart BirbaBot',
            pull => 'Execute a git pull',
            anotes => 'Admin search and deletion of pending notes: without arguments list all the pending notes | "anotes del <nick>" Deletes all pending notes from "nick".',
            op => 'op <nick> [ nick2 nick#n ]',
            deop => 'deop <nick> [ nick2 nick#n ]',
            voice => 'voice <nick> [ nick2 nick#n ]',
            devoice => 'devoice <nick> [ nick2 nick#n ]',
            k => 'kick <nick> [ reason ]',
            kb => 'kickban <nick> [ reason ]',
            mode => 'Set channels modes, like: mode +<mode>-<mode> and also users modes, like bans: mode +b nick!user@host',
	    topic => 'Set the channel topic: topic <topic>',
            timebomb => 'Game: place the bomb on <nick> panties; use cut <wire> to defuse it.',
            cut => 'Defuse the Bomb by cutting the right colored wire: cut <wire>'				      
		    },
            In_channels => 1,
	    Auth_sub => \&check_if_fucker,
	    Ignore_unauthorized => 1,
 	    In_private => 1,
            Addressed => 0,
            Prefix => $botconfig{'botprefix'},
            Eat => 1,
            Ignore_unknown => 1,
								  
								 ));
    $irc->plugin_add( 'CTCP' => POE::Component::IRC::Plugin::CTCP->new(
								       version => "BirbaBot v.$VERSION, IRC Perl Bot: https://github.com/roughnecks/BirbaBot",
								       userinfo => $ircname,
								      ));
    $irc->yield( register => 'all' );
    $irc->yield( connect => { } );
    $kernel->delay_set('save', SAVE_INTERVAL);
    # here we register the rss_sentinel
    $kernel->delay_set("reminder_sentinel", 35);  # first run after 35 seconds
    $kernel->delay_set("tail_sentinel", 40);  # first run after 40 seconds
    $kernel->delay_set("rss_sentinel", 60);  # first run after 60 seconds
    $kernel->delay_set("debget_sentinel", 180);  # first run after 180 seconds
    $lastpinged = time();
    return;
}

sub irc_botcmd_meteo {
  my ($where, $arg) = @_[ARG1, ARG2];
  if (! defined $arg) {
    bot_says($where, 'Missing location.');
    return
  } elsif ($arg =~ /^\s*$/) {
    bot_says($where, 'Missing location.');
    return
  }
  print "Asking the weatherman\n";
  bot_says($where, yahoo_meteo($arg));
  return;
}


sub bot_says {
  my ($where, $what) = @_;
  return unless ($where and (defined $what));

  # Let's use HTML::Entities
  $what = decode_entities($what);
  
#  print print_timestamp(), "I'm gonna say $what on $where\n";
  if (length($what) < 400) {
    $irc->yield(privmsg => $where => $what);
  } else {
    my @output = ("");
    my @tokens = split (/\s+/, $what);
    if ($tokens[0] =~ m/^(\s+)(.+$)/) {
      $tokens[0] = $2;
    }
    while (@tokens) {
      my $string = shift(@tokens);
      my $len = length($string);
      my $oldstringleng = length($output[$#output]);
      if (($len + $oldstringleng) < 400) {
	$output[$#output] .= " $string";
      } else {
	push @output, $string;
	if ($output[0] =~ m/^(\s+)(.+$)/) {
	  $output[0] = $2;
	}
      }
    }
    foreach my $reply (@output) {
      $irc->yield(privmsg => $where => $reply);
    }
  }
  return
}
  
sub irc_botcmd_karma {
  my ($who, $where, $arg) = @_[ARG0, ARG1, ARG2];
  my $nick = parse_user($who);
  if (($arg) && ($arg =~ m/^\s*$/)) {
    bot_says($where, karma_manage($dbh, $nick));
    return;
  } elsif (($arg) && ($arg =~ m/^\s*\S+\s*$/)) {
    $arg =~ s/\s*//g;
    bot_says($where, karma_manage($dbh, $arg));
    return;
  } else {
    # self karma
    bot_says($where, karma_manage($dbh, $nick));
    return;
  }
}



sub irc_botcmd_math {
  my ($where, $arg) = @_[ARG1, ARG2];
  if ($arg =~ m/^\s*(-?[\d\.]+)\s*([\*\+\-\/\%])\s*(-?[\d.]+)\s*$/) {
    my $first = $1;
    my $op = $2;
    my $last = $3;
    my $result;

    if (($last == 0) && (($op eq "/") or ($op eq "%"))) {
      bot_says($where, "Illegal division by 0");
      return;
    }

    if ($op eq '+') {
      $result = $first + $last;
    }
    elsif ($op eq '-') {
      $result = $first - $last;
    }
    elsif ($op eq '*') {
      $result = $first * $last;
    }
    elsif ($op eq '/') {
      $result = $first / $last;
    }
    elsif ($op eq '%') {
      $result = $first % $last;
    }
    if ($result == 0) {
      $result = "0 ";
    }
    bot_says($where, $result);
  }
  else {
    bot_says($where, "uh?");
  }
  return
}

sub irc_botcmd_bash {
  my ($where, $arg) = @_[ARG1, ARG2];
  my $good;
  if (! $arg ) {
    $good = 'random';
  } elsif ( $arg =~ m/^(\d+)/s ) {
    $good = $1;
  } else {
    return;
  }
  my $result = search_bash($good);
  if ($result) {
    foreach (split("\r*\n", $result)) {
      bot_says($where, $_);
    }
  } else {
    bot_says($where, "Quote $good not found");
  }
}



sub irc_botcmd_urban {
  my ($where, $arg) = @_[ARG1..$#_];
  my @args = split(/ +/, $arg);
  my $subcmd = shift(@args);
  my $string = join (" ", @args);
  if (! $arg) { return }
  elsif ($arg =~ m/^\s*$/) { return } 
  elsif (($subcmd) && $subcmd eq "url" && ($string)) {
    my $baseurl = 'http://www.urbandictionary.com/define.php?term=';
    my $url = $baseurl . uri_escape($string);
    bot_says($where, $url);
  } else {
    bot_says($where, search_urban($arg));
  }
}



sub irc_botcmd_rss {
  my $mask = $_[ARG0];
  my $nick = (split /!/, $mask)[0];
  my ($where, $arg) = @_[ARG1, ARG2];
  my @args = split / +/, $arg;
  my ($action, $feed, $url) = @args;
  if ($action eq 'list') {
    if ($feed or $url) {
      return bot_says($where, "Wrong argument to list (none required)");
    } else {
      my $reply = rss_list($dbh, $where);
      bot_says($where, $reply);
      return;
    }
  }
  elsif ($action eq 'show') {
    if (! $feed) {
      return bot_says($where, "I need a feed name to show.");
    } else {
      my @replies = rss_give_latest($dbh, $feed);
      foreach my $line (@replies) {
	bot_says($where, $line);
      }
    return;
    }
  }

  unless (check_if_op($where, $nick) or check_if_admin($mask)) {
    bot_says($where, "You need to be a channel operator to manage the RSS, sorry");
    return;
  }
  if (($action eq 'add') &&
      $feed && $url) {
    my $reply = rss_add_new($dbh, $feed, $where, $url);
    bot_says($where, "$reply");
  }
  elsif (($action eq 'del') && $feed) {
    my ($reply, $purged) = rss_delete_feed($dbh, $feed, $where);
    if ($reply) {
      bot_says($where, $reply);
      if ($purged && ($feed =~ m/^\w+$/)) {
	unlink File::Spec->catfile($localdir, $feed);
      }
    } else {
      bot_says($where, "Problems deleting $feed");
    }
  }
  else {
    bot_says($where, "Usage: rss add <feedname> <url>, or rss del <feedname>");
    return;
  }
}

sub irc_botcmd_slap {
    my $nick = (split /!/, $_[ARG0])[0];
    my ($where, $arg) = @_[ARG1, ARG2];
    my $botnick = $irc->nick_name;
    if ($arg =~ m/\Q$botnick\E/) {
      $irc->yield(ctcp => $where, "ACTION slaps $nick with her tail");
    } elsif ($arg =~ /^\s*$/) { 
      return
    } else {
      my $dest = $arg;
      $dest =~ s/\s+$//;
      $irc->yield(ctcp => $where, "ACTION slaps $dest with her tail");
    }
    return;
}

sub irc_botcmd_note {
    my $nick = (split /!/, $_[ARG0])[0];
    my ($where, $arg) = @_[ARG1, ARG2];
    if ($arg =~ m/\s*([^\s]+)\s+(.+)\s*$/) {
      bot_says($where, notes_add($dbh, $nick, $1, $2))
    }
    else {
      bot_says($where, "Uh? Try note nick here goes the message")
    }
    return;
}

sub irc_botcmd_notes {
  my ($who, $where, $arg) = @_[ARG0..$#_];
  my $nick = parse_user($who);
  if (! defined $arg) {
    bot_says($where, notes_pending($dbh, $nick));
  } elsif ($arg =~ /^\s*$/) {
    bot_says($where, notes_pending($dbh, $nick));
  } else {
    my ($subcmd, $fromwho) = split(/\s+/, $arg);
    if (($subcmd eq 'del') && (defined $fromwho)) {
      bot_says($where, notes_del($dbh, $nick, $fromwho));
      return
    } else { 
      bot_says($where, "Missing or invalid argument");
    }
  }
}


sub irc_botcmd_g {
  my ($where, $arg) = @_[ARG1, ARG2];
  return unless is_where_a_channel($where);
  if (($arg) && $arg =~ /^\s*$/) {
    return
  } else {
    bot_says($where, search_google($arg, "web"));
  }
}

sub irc_botcmd_gi {
  my ($where, $arg) = @_[ARG1, ARG2];
  return unless is_where_a_channel($where);
  if (($arg) && $arg =~ /^\s*$/) {
    return
  } else { 
    bot_says($where, search_google($arg, "images"));
  }
}

sub irc_botcmd_gv {
  my ($where, $arg) = @_[ARG1, ARG2];
  return unless is_where_a_channel($where);
  if (($arg) && $arg =~ /^\s*$/) {
    return
  } else { 
    bot_says($where, search_google($arg, "video"));
  }
}

sub irc_botcmd_gw {
  my ($where, $arg) = @_[ARG1, ARG2];
  return unless is_where_a_channel($where);
  if (($arg) && $arg =~ /^\s*$/) {
    return
  } else {
    my $prefix = 'site:en.wikipedia.org ';
    bot_says($where, search_google($prefix.$arg, "web"));
  }
}




sub irc_botcmd_imdb {
  my ($where, $arg) = @_[ARG1, ARG2];
  if ($arg =~ /^\s*$/) {
    return
  } else {
    bot_says($where, search_imdb($arg));
  }
}


sub irc_botcmd_geoip {
    my $nick = (split /!/, $_[ARG0])[0];
    my ($where, $arg) = @_[ARG1, ARG2];
    return unless is_where_a_channel($where);
    $irc->yield(privmsg => $where => BirbaBot::Geo::geo_by_name_or_ip($arg));
    return;
}

sub irc_botcmd_done {
  my ($who, $chan, $arg) = @_[ARG0, ARG1, ARG2];
  my $nick = (split /!/, $_[ARG0])[0];
  #  bot_says($chan, $irc->nick_channel_modes($chan, $nick));
  unless (check_if_op($chan, $nick) or check_if_admin($who)) {
    bot_says($chan, "You're not a channel operator. " . todo_list($dbh, $chan));
    return
  }
  if ($arg =~ m/^([0-9]+)$/) {
    bot_says($chan, todo_remove($dbh, $chan, $1));      
  } else {
    bot_says($chan, "Give the numeric index to delete the todo")
  }
  return;
}

sub irc_botcmd_todo {
  my ($who, $chan, $arg) = @_[ARG0, ARG1, ARG2];
  my $nick = (split /!/, $_[ARG0])[0];
#  bot_says($chan, $irc->nick_channel_modes($chan, $nick));
  unless (($irc->is_channel_operator($chan, $nick)) or 
	  ($irc->nick_channel_modes($chan, $nick) =~ m/[aoq]/)
	  or check_if_admin($who))
    {
    bot_says($chan, "You're not a channel operator. " . todo_list($dbh, $chan));
    return
  }
   my @commands_args;
  if ($arg) {
    @commands_args = split(/\s+/, $arg);
  }
  my $task = "none";
  if (@commands_args) {
    $task = shift(@commands_args);
  }
  my $todo;
  if (@commands_args) {
    $todo = join " ", @commands_args;
  }
  if ($task eq "list") {
    bot_says($chan, todo_list($dbh, $chan));
  } 
  elsif ($task eq "add") {
    bot_says($chan, todo_add($dbh, $chan, $todo))
  }
  elsif (($task eq "del") or 
	 ($task eq "delete") or
	 ($task eq "remove") or
	 ($task eq "done")) {
    if ($todo =~ m/^([0-9]+)$/) {
      bot_says($chan, todo_remove($dbh, $chan, $1));      
    } else {
      bot_says($chan, "Give the numeric index to delete the todo")
    }
  }
  elsif ($task eq "rearrange") {
    bot_says($chan, todo_rearrange($dbh, $chan))
  }
  else {
    bot_says($chan, todo_list($dbh, $chan));
  }
  return
}


# non-blocking dns lookup
sub irc_botcmd_lookup {
    my $nick = (split /!/, $_[ARG0])[0];
    my ($where, $arg) = @_[ARG1, ARG2];
    return unless is_where_a_channel($where);
    if ($arg =~ m/(([0-9]{1,3}\.){3}([0-9]{1,3}))/) {
      my $ip = $1;
      # this is from `man perlsec` so it has to be safe
      die "Can't fork: $!" unless defined(my $pid = open(KID, "-|"));
      if ($pid) {           # parent
	while (<KID>) {
	  bot_says($where, $_);
	}
	close KID;
	return;
      } else {
	# this is the external process, forking. It never returns
	exec 'host', $ip or die "Can't exec host: $!";
      }
    }
    my ($type, $host) = $arg =~ /^(?:(\w+) )?(\S+)/;
    return unless $host;
    my $res = $dns->resolve(
        event => 'dns_response',
        host => $host,
        type => $type,
        context => {
            where => $where,
            nick  => $nick,
        },
    );
    $poe_kernel->yield(dns_response => $res) if $res;
    return;
}

sub dns_response {
    my $res = $_[ARG0];
    my @answers = map { $_->rdatastr } $res->{response}->answer() if $res->{response};

    $irc->yield(
        'notice',
        $res->{context}->{where},
        $res->{context}->{nick} . (@answers
            ? ": @answers"
            : ': no answers for "' . $res->{host} . '"')
    );

    return;
}

sub irc_disconnected {
  print print_timestamp(), "Reconnecting in $reconnect_delay seconds\n";
  $irc->delay([ connect => { }], $reconnect_delay);
}

sub irc_error {
  print print_timestamp(), "Reconnecting in $reconnect_delay seconds\n";
  $irc->delay([ connect => { }], $reconnect_delay);
}

sub irc_socketerr {
  print print_timestamp(), "Reconnecting in $reconnect_delay seconds\n";
  $irc->delay([ connect => { }], $reconnect_delay);
}

sub irc_001 {
    my ($kernel, $sender) = @_[KERNEL, SENDER];

    # Since this is an irc_* event, we can get the component's object by
    # accessing the heap of the sender. Then we register and connect to the
    # specified server.
    my $irc = $sender->get_heap();

    print print_timestamp(), "Connected to ", $irc->server_name(), "\n";

    # we join our channels waiting a few secs
    foreach (@channels) {
      $irc->delay( [ join => $_ ], 10 ); 
    }

    return;
}

sub irc_notice {
  my ($who, $text) = @_[ARG0, ARG2];
  my $nick = parse_user($who);
  print "Notice from $who: $text", "\n";
  if ( ($nick eq 'NickServ' ) && ( $text =~ m/^This\snickname\sis\sregistered.+$/ || $text =~ m/^This\snick\sis\sowned\sby\ssomeone\selse\..+$/ ) ) {
    my $passwd = $botconfig{'nspassword'};
    $irc->yield( privmsg => "$nick", "IDENTIFY $passwd");
  }
}

sub irc_ping {
  print "Ping!\n";
  $lastpinged = time();
}

sub irc_kick {
  my $kicker = $_[ARG0];
  my $channel = $_[ARG1];
  my $kicked = $_[ARG2];
  my $botnick = $irc->nick_name;
  return unless $kicked eq $botnick;
  sleep 5;
  $kicker = parse_user($kicker);
  $irc->yield( join => $channel );
  bot_says($channel, "$kicker: :-P");
}

sub save {
    my $kernel = $_[KERNEL];
    warn "storing\n";
    store($seen, DATA_FILE) or die "Can't save state";
    $kernel->delay_set('save', SAVE_INTERVAL);
}

sub irc_ctcp_action {
    my $nick = parse_user($_[ARG0]);
    my $chan = $_[ARG1]->[0];
    my $text = $_[ARG2];

    add_nick($nick, "on $chan doing: * $nick $text");
}

sub irc_join {
    my $nick = parse_user($_[ARG0]);
    my $chan = $_[ARG1];
    my @notes = notes_give($dbh, $nick);
    add_nick($nick, "joining $chan");
    while (@notes) {
      bot_says($nick, shift(@notes));
    }
}

sub irc_part {
    my $nick = parse_user($_[ARG0]);
    my $chan = $_[ARG1];
    my $text = $_[ARG2];

    my $msg = "parting " . $chan;
    $msg .= " with message '$text'" if defined $text;

    add_nick($nick, $msg);
}

sub irc_quit {
  my $nick = parse_user($_[ARG0]);
  my $text = $_[ARG1];

  my $msg = 'quitting';
  $msg .= " with message '$text'" if defined $text;

  add_nick($nick, $msg);
}



sub irc_public {
    my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];
    my $botnick = $irc->nick_name;

    # debug log
    if ($msg_log == 1) {
      print print_timestamp(), "$nick/$channel: $what\n";
    }

    # relay stuff
    if (($relay_source) && ($relay_dest)) {
      if ($channel eq $relay_source) {
	foreach ($what) {
	  $what = irc_to_utf8($what);
	  bot_says($relay_dest, "\[$relay_source/$nick\]: $what")
	}
      }
    }

    if ( ($twoways_relay == 1) && ($relay_source) && ($relay_dest)) {
      if ($channel eq $relay_dest) {
	foreach ($what) {
	  $what = irc_to_utf8($what);
	  bot_says($relay_source, "\[$relay_dest/$nick\]: $what")
	}
      }
    }
    # seen stuff
    add_nick($nick, "on $channel saying: $what");

    # if it's a fucker, do nothing
    my ($auth, $spiterror) = check_if_fucker($sender, $who, $where, $what);
    return unless $auth;

    # keywords
    if ($botconfig{'kw_prefix'}) {
      if (index($what, $botconfig{'kw_prefix'}) == 0) {
	# strip the prefix and pass all to the subroutine
	my $querystripped = substr($what, 1);
	if ((index($querystripped, ' >')) < 0) {
	  # simulate the question for the poor bastards using the kw_prefix
	  $querystripped .= '?';
	}
	return _kw_manage_request($querystripped, $nick, $where, $channel)
      }
    } else {
      _kw_manage_request($what, $nick, $where, $channel)
    }
    
    if ($what =~ /((AH){2,})/) {
      bot_says($channel, "AHAHAHAHAHAH!");
      return;
    }
    if ($what =~ /^\s*([^\s]+)(\+\+|--)(\s+#.+)?\s*$/) {
      my $karmanick = $1;
      my $karmaaction = $2;
      if ($karmanick eq $nick) {
	bot_says($channel, "You're cheating, moron!");
	return;
      } 
      elsif (! $irc->is_channel_member($channel, $karmanick)) {
	print "$karmanick is not here, skipping\n";
	return;
      }
      elsif ($karmanick eq $botnick) {
	if ($karmaaction eq '++') {
	  bot_says($channel, "meeow")
	} else {
	  bot_says($channel, "fhhhhrrrrruuuuuuuuuuu")
	}
	print print_timestamp(),
	  karma_manage($dbh, $karmanick, $karmaaction), "\n";
	return;
      }
      else {
	bot_says($channel, karma_manage($dbh, $karmanick, $karmaaction));
	return;
      }
    }
    # this will push in @longurls
    $urifinder->find(\$what);
    while (@longurls) {
      my $url = shift @longurls;
#      print "Found $url\n";
      if ($url =~ m/^https?:\/\/(www\.)?youtube/) {
	bot_says($channel, get_youtube_title($url));
      }
      if ($url =~ m/youtu\.be\/(.+)$/) {
	my $newurl = "http://www.youtube.com/watch?v="."$1";
	bot_says($channel, get_youtube_title($newurl));
      }	

      next if (length($url) <= 65);
      next unless ($url =~ m/^(f|ht)tp/);
      my $reply = $nick . "'s url: " . make_tiny_url($url);
      bot_says($channel, $reply);
    }
    
#     elsif (($what =~ /\?$/) and (int(rand(6)) == 1)) {
#       bot_says($channel, "RTFM!");
#     }
#    if ($what eq "hi") {
#      if (check_if_admin($who)) {
#	bot_says($where, "Hello my master");
#      } else {
#	bot_says($where, "And who the hell are you?");
#      }
#    }
    return;
}

sub irc_msg {
  my ($who, $what) = @_[ARG0, ARG2];
  my $nick = parse_user($who);
  
  if ( $what =~ /^(.+)\?\s*$/ ) {
    print "info: requesting keyword $1\n";
    my $kw = $1;
    my $query = (kw_query($dbh, $nick, lc($kw)));
    if (($query) && ($query =~ m/^ACTION\s(.+)$/)) {
      $irc->yield(ctcp => $nick, "ACTION $1");
      return;
    } elsif ($query) {
      bot_says($nick, $query);
    return;
    }
  }
}


sub add_nick {
  my ($nick, $msg) = @_;
  $seen->{l_irc($nick)} = [time, $msg];
}

sub irc_botcmd_seen {
  my ($heap, $nick, $channel, $target) = @_[HEAP, ARG0..$#_];
  $nick = parse_user($nick);
  if (($target) && $target =~ m/^\s+$/) {
    return;
  } elsif (! defined $target) { 
    return;
  }
  elsif ($target) {
    $target =~ s/\s+//g;
  }
  my $botnick = $irc->nick_name;
#  print "processing seen command\n";
  if ($seen->{l_irc($target)}) {
    my $date = localtime $seen->{l_irc($target)}->[USER_DATE];
    my $msg = $seen->{l_irc($target)}->[USER_MSG];
    if ("$target" eq "$nick") {
      $irc->yield(privmsg => $channel, "$nick: Looking for yourself, ah?");
    } elsif ($target =~ m/\Q$botnick\E/) {
      $irc->yield(privmsg => $channel, "$nick: I'm right here!");
    } elsif ($irc->is_channel_member($channel, $target)) {
      $irc->yield(privmsg => $channel,
                  "$nick: $target is here and i last saw $target at $date $msg.");
    } else {
      $irc->yield(privmsg => $channel, "$nick: I last saw $target at $date $msg");
    }
  } else {
    if ($irc->is_channel_member($channel, $target)) {
      $irc->yield(privmsg => $channel,
                  "$nick: $target is here but he didn't say a thing, AFAIK.");
    } else {
      $irc->yield(privmsg => $channel, "$nick: I haven't seen $target");
    }
  }
}

sub irc_botcmd_quote {
  my ($who, $where, $what) = @_[ARG0..$#_];
  my $nick = parse_user($who);
  my @args = split(/ +/, $what);
  my $subcmd = shift(@args);
  my $string = join (" ", @args);
  my $reply;
  if ($subcmd eq 'add' && $string =~ /.+/) {
    $reply = ircquote_add($dbh, $who, $where, $string)
  } elsif ($subcmd eq 'del' && $string =~ /.+/) {
    $reply = ircquote_del($dbh, $who, $where, $string)
  } elsif ($subcmd eq 'rand') {
    $reply = ircquote_rand($dbh, $where)
  } elsif ($subcmd eq 'last') {
    $reply = ircquote_last($dbh, $where)
  } elsif ($subcmd =~ m/([0-9]+)/) {
    $reply = ircquote_num($dbh, $1, $where)
  } elsif ($subcmd eq 'find' && $string =~ /.+/) {
    $reply = ircquote_find($dbh, $where, $string)
  } else {
    $reply = "command not supported"
  }
  bot_says($where, $reply);
  return
}

sub rss_sentinel {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my $currentime = time();
  if (($currentime - $lastpinged) > 200) {
    print print_timestamp(), "no ping in more then 200 secs, checking\n";
    $irc->yield( userhost => $serverconfig{nick} );
    $lastpinged = time();
    $kernel->delay_set("rss_sentinel", $botconfig{rsspolltime});
    return
  }
  print print_timestamp(), "Starting fetching RSS...\n";
  my $feeds = rss_get_my_feeds($dbh, $localdir);
  foreach my $channel (keys %$feeds) {
    foreach my $feed (@{$feeds->{$channel}}) {
      $irc->yield( privmsg => $channel => $feed);
    }
  }
  print print_timestamp(), "done!\n";
  # set the next loop
  $kernel->delay_set("rss_sentinel", $botconfig{rsspolltime})
}

sub tail_sentinel {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my $what = $botconfig{tail};
  my @ignored = @{$botconfig{'ignored_lines'}};
  return unless (%$what);
  foreach my $file (keys %{$what}) {
    my $channel = $what->{$file};
    my @things_to_say = file_tail($file);
    while (@things_to_say) {
      my $thing = shift @things_to_say;
      next if ($thing =~ m/^\s*$/);
      # see if the line should be ignored
      my $in_ignore;
      foreach my $ignored (@ignored) {
	if ((index $thing, $ignored) >= 0) {
	  $in_ignore++;
	}
      }
      bot_says($channel, $thing) unless $in_ignore;
    }
  }
  $kernel->delay_set("tail_sentinel", 60)
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
            push ( @output, "'$arg'" ) unless (! $arg);
        }
    }
    print print_timestamp(), join ' ', @output, "\n";
    return 0;
}

sub print_timestamp {
    my $time = localtime();
    return "[$time] "
}

sub process_admin_list {
  my @masks = @_;
  my @regexp;
  foreach my $mask (@masks) {
    # first, we check nick, username, host. The *!*@* form is required
    if ($mask =~ m/(.+)!(.+)@(.+)/) {
      $mask =~ s/(\W)/\\$1/g;	# escape everything which is not a \w
      $mask =~ s/\\\*/.*?/g;	# unescape the *
      push @regexp, qr/^$mask$/;
    } else {
      print "Invalid mask $mask, must be in *!*@* form"
    }
  }
  print Dumper(\@regexp);
  return @regexp;
}

sub check_if_admin {
  my $mask = shift;
  return 0 unless $mask;
  foreach my $regexp (@adminregexps) {
    if ($mask =~ m/$regexp/) {
      return 1
    }
  }
  return 0;
}

sub check_if_op {
  my ($chan, $nick) = @_;
  return 0 unless $nick;
  if (($irc->is_channel_operator($chan, $nick)) or 
      ($irc->nick_channel_modes($chan, $nick) =~ m/[aoq]/)) {
    return 1;
  }
  else {
    return 0;
  }
}

sub check_if_fucker {
  my ($object, $nick, $place, $command, $args) = @_;
#  print "Authorization for $nick";
  foreach my $pattern (@fuckers) {
    if ($nick =~ m/\Q$pattern\E/i) {
#      print "$nick match $pattern?";
      return 0, [];
    }
  }
  return 1;
}

sub is_where_a_channel {
  my $where = shift;
  if ($where =~ m/^#/) {
    return 1
  } else {
    return 0
  }
}

sub irc_botcmd_choose {
  my ($where, $args) = @_[ARG1..$#_];
  my @choises = split(/ +/, $args);
  foreach ( @choises ) {
    $_ =~ s/^\s*$//;
  }
  unless ($#choises > 0) {
    bot_says ($where, 'Provide at least 2 arguments');
  } else {
    my %string = map { $_, 1 } @choises;
    if (keys %string == 1) {
      # all equal
      bot_says($where, 'That\'s an hard guess for sure :P');
    } else {
      my $lenght = scalar @choises;
      my $random = int(rand($lenght));
      bot_says($where, "$choises[$random]");
    }
  }
}
  
sub irc_botcmd_version {
  my $where = $_[ARG1];
      die "Can't fork: $!" unless defined(my $pid = open(KID, "-|"));
  if ($pid) { # parent
    while (<KID>) {
      my $line = $_;
      unless ($line =~ m/^\s*$/) {
	bot_says($where, $line);
      }
    }
    close KID;
    return;
  } else {
    # this is the external process, forking. It never returns
    my @command = ('git', 'log', '-n', '1');
    exec @command or die "Can't exec git: $!";
  }
}

sub irc_botcmd_remind {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my ($who, $where, $what) = @_[ARG0..$#_];
  my $nick = parse_user($who);
  my $seconds;
  my @args = split(/ +/, $what);
  my $time = shift(@args);
  my $string = join (" ", @args);
  if (($string) && defined $string) {
    if (($time) && defined $time && $time =~ m/^(\d+)d(\d+)h(\d+)m$/) {
      $seconds = ($1*86400)+($2*3600)+($3*60);
    } elsif (($time) && defined $time && $time =~ m/^(\d+)h(\d+)m$/) {
      $seconds = ($1*3600)+($2*60);
    } elsif (($time) && defined $time && $time =~ m/^(\d+)m?$/) {
      $seconds = $1*60;
    } else {
      bot_says($where, 'Wrong syntax: ask me "help remind" <= This is for the lazy one :)');
      return
    }
  } else {
    bot_says($where, 'Missing argument');
    return
  }
  my $delay = time() + $seconds;
  my $query = $dbh->prepare("INSERT INTO reminders (chan, author, time, phrase) VALUES (?, ?, ?, ?);");
  $query->execute($where, $nick, $delay, $string);
  my $select = $dbh->prepare("SELECT id FROM reminders WHERE chan = ? AND author = ? AND phrase = ?;");
  $select->execute($where, $nick, $string);
  my $id = $select->fetchrow_array();
  my $delayed = $irc->delay ( [ privmsg => $where => "$nick, it's time to: $string" ], $seconds );
  $_[KERNEL]->delay_add(reminder_del => $seconds => $id);
  bot_says($where, 'Reminder added.');
}

sub reminder_sentinel {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my $query = $dbh->prepare("SELECT id,chan,author,time,phrase FROM reminders;");
  $query->execute();
  while (my @values = $query->fetchrow_array()) {
    my $now = time();
    my $time = $values[3];
    my $where = $values[1];
    my $nick = $values[2];
    my $string = $values[4];
    my $id = $values[0];
    if ($time > $now) {
      my $new_delay = $time - $now;
      my $delayed = $irc->delay ( [ privmsg => $where => "$nick, it's time to: $string" ], $new_delay );
      $_[KERNEL]->delay_add(reminder_del => $new_delay => $id);
    } else {
      bot_says($where, "$nick: reminder expired before execution; was: $string");
      my $del_query = $dbh->prepare("DELETE from reminders WHERE id = ?;");
      $del_query->execute($id);
    }
  }
}

sub reminder_del {
  my ($kernel, $sender, $id) = @_[KERNEL, SENDER, ARG0];
  my $del_query = $dbh->prepare("DELETE from reminders WHERE id = ?;");
  $del_query->execute($id);
  print "reminder deleted\n";
}

sub irc_botcmd_lremind {
  my $where = $_[ARG1];
  my $query = $dbh->prepare("SELECT id,author,time,phrase FROM reminders WHERE chan= ? ORDER by time ASC;");
  $query->execute($where);
  my $count;
  while (my @values = $query->fetchrow_array()) {
    my $now = time();
    my $time = $values[2];
    my $nick = $values[1];
    my $string = $values[3];
    $string = $bbold . $string . $ebold;
    my $id = $values[0];
    my $eta = $time - $now;
    my $days = int($eta/(24*60*60));
    my $hours = ($eta/(60*60))%24;
    my $mins = ($eta/60)%60;
    bot_says($where, "Reminder $id for $nick: $string, happens in $days day(s), $hours hour(s) and $mins minute(s)");
    $count++
  }
  bot_says($where, "No active reminders for $where") unless $count;
}


sub irc_botcmd_wikiz {
  my ($where, $arg) = @_[ARG1, ARG2];

  # get the sitemap
  my $file = get 'http://laltromondo.dynalias.net/~iki/sitemap/index.html';
  my $prepend = 'http://laltromondo.dynalias.net/~iki';
  my @out = ();

  # split sitemap in an array and extract urls
  my @list = split ( /(<.+?>)/, $file );
  my @formatlist = grep ( /href="(\.\.)(.+?)"/, @list );

  # grep the formatted list of url searching for pattern
  if (! defined $arg) {
    bot_says($where, 'Missing Argument');
    return
  } elsif ($arg =~ /^\s*$/) {
    bot_says($where, 'Missing Argument');
    return
    } else {
      @out = grep ( /\Q$arg\E/i , @formatlist );
    }
  # looping through the output of matching urls, clean some shit and spit to channel

  my %hash;
  foreach my $item (@out) {
    $item =~ m!href="(\.\.)(.+?)"!;
    $hash{$2} = 1;
  }
  @out = keys %hash;

  if (@out) {
    foreach (@out) {
      bot_says ($where, $prepend .$_);
    }
  } else {
    bot_says ($where, 'No matches found.');
  }
}

sub irc_botcmd_isdown {
  my ($where, $what) = @_[ARG1, ARG2];
  return unless is_where_a_channel($where);
  if ($what =~ m/^\s*(http\:\/\/)?(\www\.)?([a-zA-Z0-9][\w\.-]+\.[a-z]{2,4})\/?\s*$/) {
    $what = $2 . $3;
    if ($what =~ m/^\s*(www\.)?downforeveryoneorjustme\.com\s*/) {
      bot_says($where, 'You just found egg #1: http://laltromondo.dynalias.net/~img/images/sitedown.png');
      return;
    }
  } else {
    bot_says($where, "Uh?");
    return;
  }
  my $prepend = 'http://www.downforeveryoneorjustme.com/';
  my $query = $prepend . $what;
  #  print "Asking downforeveryoneorjustme for $query\n";
  my $file = get "$query";
  if ( $file =~ m|<div\ id\=\"container\">(.+)</p>|s ) {
    my $result = $1;
    my $hs = HTML::Strip->new();
    my $clean_text = $hs->parse( $result );
    $hs->eof;
    chomp($clean_text);
    $clean_text =~ s/\s+/ /g;
    $clean_text =~ s/^\s+//;
    bot_says($where, $clean_text);
  }
}

sub irc_botcmd_uptime {
  my $where = $_[ARG1];
  my $now = time;
  my $uptime = $now - $starttime;
  my $days = int($uptime/(24*60*60));
  my $hours = ($uptime/(60*60))%24;
  my $mins = ($uptime/60)%60;
  my $secs = $uptime%60;
  bot_says($where, "uptime: $days day(s), $hours hour(s), $mins minute(s) and $secs sec(s).");
}


sub irc_botcmd_free {
  my $mask = $_[ARG0];
  my $nick = (split /!/, $mask)[0];
  my $where = $_[ARG1];
  unless (check_if_op($where, $nick) or check_if_admin($mask)) {
    bot_says($where, "You need to be a bot/channel operator, sorry");
    return;
  }
      die "Can't fork: $!" unless defined(my $pid = open(KID, "-|"));
  my %freestats = (
		   total => "n/a",
		   used => "n/a",
		   free => "n/a",
		   swaptot => "n/a",
		   swapused => "n/a",
		   swapfree => "n/a",
		  );
  if ($pid) { # parent
    while (<KID>) {
      my $line = $_;
      if ($line =~ m/^Mem\:\s+(\d+)\s+/) {
	$freestats{total} = $1;
      } elsif ($line =~ m/^\-\/\+ buffers\/cache\:\s+(\d+)\s+(\d+)/) {
	$freestats{used} = $1;
	$freestats{free} = $2;
      } elsif ($line =~ m/^Swap\:\s+(\d+)\s+(\d+)\s+(\d+)/) {
	$freestats{swaptot} = $1;
	$freestats{swapused} = $2;
	$freestats{swapfree} = $3;
      }
    }
    close KID;
    my $output = "Memory: used " . $freestats{used} . "/" . $freestats{total} .
      "MB, " . $freestats{free} . "MB free. Swap: used " . $freestats{swapused} .
	"/" . $freestats{swaptot} . "MB";
    undef %freestats;
    bot_says($where, $output);
    return;
  } else {
    # this is the external process, forking. It never returns
    my @command = ('free', '-m');
    exec @command or die "Can't exec git: $!";
  }
}

sub irc_botcmd_restart {
  my ($kernel, $who, $where, $arg) = @_[KERNEL, ARG0, ARG1, ARG2];
  return unless (sanity_check($who, $where));
  $poe_kernel->signal($poe_kernel, 'POCOIRC_SHUTDOWN', 'Goodbye, cruel world');
  $kernel->delay_set(greetings_and_die => 10);
}

sub irc_botcmd_pull {
  my ($who, $where, $arg) = @_[ARG0, ARG1, ARG2];
  return unless (sanity_check($who, $where));
  my $gitorigin = `git config --get remote.origin.url`;
  if ($gitorigin =~ m!^\s*ssh://!) {
    bot_says($where, "Your git uses ssh, I can't safely pull");
    return;
  }
  die "Can't fork: $!" unless defined(my $pid = open(KID, "-|"));
  if ($pid) {           # parent
    while (<KID>) {
      bot_says($where, $_);
    }
    close KID;
    return;
  } else {
    my @command = ("git", "pull");
    # this is the external process, forking. It never returns
    exec @command or die "Can't exec git: $!";
  }
  return;
}


sub sanity_check {
  my ($who,$where) = @_;
  return unless $who;
  return unless $where;
  unless (check_if_admin($who)) {
    bot_says($where, "Who the hell are you?");
    return undef;
  };
  if ((-e basename($0)) &&
      (-d ".git") &&
      (-d "BirbaBot") &&
      (check_if_admin($who))) {
    return 1;
  } else {
    bot_says($where, "I can't find myself");
    return undef;
  }
}


sub greetings_and_die {
  $ENV{PATH} = "/bin:/usr/bin"; # Minimal PATH.
  my @command = ('perl', $0, @ARGV);
  exec @command or die "can't exec myself: $!";
}

sub irc_botcmd_anotes {
  my ($who, $where, $arg) = @_[ARG0..$#_];
  my $nick = parse_user($who);
  unless (check_if_admin($who)) {
    bot_says($where, "You need to be an admin, sorry");
    return;
  }
  if (! defined $arg) {
    bot_says($where, anotes_pending($dbh));
  } elsif ($arg =~ /^\s*$/) {
    bot_says($where, anotes_pending($dbh));
  } else {
    my ($subcmd, $fromwho) = split(/\s+/, $arg);
    if (($subcmd eq 'del') && (defined $fromwho)) {
      bot_says($where, anotes_del($dbh, $fromwho));
      return;
    } else {
      bot_says($where, "Missing or invalid argument");
    }
  }
}



sub irc_botcmd_kw {
  my ($who, $where, $arg) = @_[ARG0..$#_];
  my $nick = parse_user($who);
  if (! $arg) {
    bot_says($where, "$nick, Missing Arguments: ask me 'help kw'");
    return
  }
  my @args = split(/\s+/, $arg);
  my $subcmd = shift(@args);
  my $string = join (" ", @args);

  # first manage the "easy" subcommands
  # list, no arguments
  if ($subcmd eq 'list') {
    return bot_says($where, kw_list($dbh))
  }

  # other subcommands have arguments, so do the check
  return bot_says($where, "No argument provided") unless $string;
  
  # sanity checks
  if ($subcmd eq 'find') {
    if (is_where_a_channel($where)) {
      return bot_says($where, "$nick, this command works only in a query");
    }
  }

  # prevent the abusing
  if ($subcmd =~ m/^(new|add|delete|forget)$/) {
    return bot_says($where, "This command works only in a channel")
      unless ((is_where_a_channel($where)) or check_if_admin($who)); 
  }
  if ($subcmd eq 'forget') {
    return bot_says($where, "Only admins can make me forget that")
      unless check_if_admin($who);
  }

  # identify the target
  my $target;
  my $definition;
  my $slot;
  # forget, show and find  has 1 argument, verbatim
  if (($subcmd eq 'forget') or
      ($subcmd eq 'show') or
      ($subcmd eq 'find')) {
    $target = lc($string);
  }
  # delete is the same, plus the [#]
  if ($subcmd eq 'delete') {
    if ($string =~ /^\s*(.+)\s+([23])\s*$/) {
      $target = lc($1);
      $slot = $2;
    } else {
      return bot_says($where, "Wrong delete command");
    }
  }

  # new and add has the "is" as separator, unless there are the ""
  if (($subcmd eq 'new') or
      ($subcmd eq 'add')) {
    if ($string =~ m/^\s*"(.+?)"\s+is+(.+)\s*$/) {
      ($target, $definition) = (lc($1), $2);
    } elsif ($string =~ m/^\s*(.+?)\s+is\s+(.+)\s*$/) {
      ($target, $definition) = (lc($1), $2);
    } else {
      return bot_says("Missing argument");
    }
  }
  
  
  if ($subcmd eq 'find') {
    bot_says($where, kw_find($dbh, $target))
  } elsif ($subcmd eq 'add') {
    bot_says($where, kw_add($dbh, $who, $target, $definition))
  } elsif ($subcmd eq 'new') {
    bot_says($where, kw_new($dbh, $who, $target, $definition))
  } elsif ($subcmd eq 'forget') {
    bot_says($where, kw_remove($dbh, $who, $target))
  } elsif ($subcmd eq 'delete') {
    bot_says($where, kw_delete_item($dbh, $target, $slot))
  } elsif ($subcmd eq 'show') {
    bot_says($where, kw_show($dbh, $target))
  } else {
    bot_says($where, "wtf?")
  }
  return
}



sub debget_sentinel {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my $cwd = getcwd();
  my $path = File::Spec->catdir($cwd, 'debs');
  make_path("$path") unless (-d $path);

  my @debrels = @{$debconfig{debrels}};
  return unless @debrels;
  foreach my $rel (@debrels) {
    next unless ($rel->{rel} and $rel->{url});
    print "Saving ", $rel->{rel}, "..\n";
    # WARNING! THE CONTENT IS GZIPPED, BUT UNCOMPRESSED BY GET
    my $file = File::Spec->catfile($path, $rel->{rel});
    $ENV{PATH} = "/bin:/usr/bin"; # Minimal PATH.
    my $tmpfile = File::Temp->new();
    my @command = ('curl', '-s', '--compressed', '--connect-timeout', '10',
		   '--max-time', '10',
		   '--output', $tmpfile->filename, $rel->{url});
    print "Trying ", join(" ", @command, "\n");
    if (system(@command) == 0) {
      copy($tmpfile->filename, $file)
    } else {
      print "failed ", join(" ", @command), "\n";
    }
  }
  $kernel->delay_set("debget_sentinel", 43200 ); #updates every 12H
  print "debget executed succesfully, files saved.\n";
}


sub irc_botcmd_deb {
  my ($where, $arg) = @_[ARG1, ARG2];
  return unless $arg =~ m/\S/;
  my @out = deb_pack_versions($arg,
			      $debian_relfiles_base, 
			      $debconfig{debrels});
  if (@out) {
    bot_says($where, "Package $arg: ". join(', ', @out));
  } else {
    bot_says($where, "No packs for $arg");
  }
}


sub irc_botcmd_debsearch {
  my ($where, $arg) = @_[ARG1, ARG2];
  my $result = deb_pack_search($arg, $debian_relfiles_base, $debconfig{debrels});
  if ($result) {
    bot_says($where, $result);
  } else {
    bot_says($where, "No result found");
  }
}


### keyword stuff

sub _kw_manage_request {
  my ($what, $nick, $where, $channel) = @_;
  print_timestamp(join ":", @_);
  if ( $what =~ /^(.+)\?\s*$/ ) {
    print "info: requesting keyword $1\n";
    my $kw = $1;
    my $query = (kw_query($dbh, $nick, lc($kw)));
    if (($query) && ($query =~ m/^ACTION\s(.+)$/)) {
      $irc->yield(ctcp => $where, "ACTION $1");
      return;
    } elsif ($query) {
      bot_says($channel, $query);
      return;
    }
  } elsif ( my ($kw) = $what =~ /^(.+)\s+>{1}\s+([\S]+)\s*$/ ) {
    my $target = $2;
    my $query = (kw_query($dbh, $nick, lc($1)));
    if ($irc->is_channel_member($channel, $target)) {
      if ((! $query) or ( $query =~ m/^ACTION\s(.+)$/ )) {
	bot_says($channel, "$nick, that fact does not exist or it can't be told to $target; try \"kw show $kw\" to see its content.");
	return;
      } else {
	bot_says($channel, "$target: "."$query");
      } 
    }
  } elsif ( my ($kw2) = $what =~ /^(.+)\s+>{2}\s+([\S]+)\s*$/ ) {
    my $target = $2;
    my $query = (kw_query($dbh, $nick, lc($1)));
    if ($irc->is_channel_member($channel, $target)) {
      if ((! $query ) or ($query =~ m/^ACTION\s(.+)$/)) {
	bot_says($channel, "$nick, that fact does not exist or it can't be told to $target; try \"kw show $kw2\" to see its content.");
	return;
      } else {
	$irc->yield(privmsg => $target, "$kw2 is $query");
	$irc->yield(privmsg => $nick, "Told $target about $kw2");
      }
    } else {
      bot_says($channel, "Dunno about $target");
      return;
    }
  }
  return;
}


## Public Commands - pc

sub irc_botcmd_op {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  return unless (check_if_op($channel, $nick) || check_if_admin($who)) ;
  my @args = "";
  if (! $what) {
    @args = ("$nick");
  } else {
    @args = split(/ +/, $what);
  }
  my $status = '+o';
  pc_status($status, $channel, $botnick, @args);
}

sub irc_botcmd_deop {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  return unless (check_if_op($channel, $nick) || check_if_admin($who)) ;
  my @args = "";
  if (! $what) {
    @args = ("$nick");
  } else {
    @args = split(/ +/, $what);
  }
  my $status = '-o';
  pc_status($status, $channel, $botnick, @args);
}

sub irc_botcmd_voice {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  return unless (check_if_op($channel, $nick) || check_if_admin($who)) ;
  my @args = "";
  if (! $what) {
    @args = ("$nick");
  } else {
    @args = split(/ +/, $what);
  }
  my $status = '+v';
  pc_status($status, $channel, $botnick, @args);
}

sub irc_botcmd_devoice {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  return unless (check_if_op($channel, $nick) || check_if_admin($who)) ;
  my @args = "";
  if (! $what) {
    @args = ("$nick");
  } else {
    @args = split(/ +/, $what);
  }
  my $status = '-v';
  pc_status($status, $channel, $botnick, @args);
}

sub irc_botcmd_k {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  return unless (check_if_op($channel, $nick) || check_if_admin($who)) ;
  if (! $what) {
    bot_says($channel, 'lemme know who has to be kicked');
    return;
  } else {
    my @args = split(/ +/, $what);
    my $target = shift(@args);
    my $reason = join (" ", @args);    
    pc_kick($nick, $target, $channel, $botnick, $reason);
  }
}

sub irc_botcmd_kb {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  return unless (check_if_op($channel, $nick) || check_if_admin($who)) ;
  if (! $what) {
    bot_says($channel, 'lemme know who has to be kicked');
    return;
  } else {
    my $mode = '+b';
    my @args = split(/ +/, $what);
    my $target = shift(@args);
    my $reason = join (" ", @args);    
    pc_ban($mode, $channel, $botnick, $target);
    pc_kick($nick, $target, $channel, $botnick, $reason);
  }
}

sub pc_status {
  my ($status, $channel, $botnick, @args) = @_;
  if (! check_if_op($channel, $botnick)) {
    bot_says($channel, "I need op");
    return
  }
  foreach (@args) {
    next if ("$_" eq "$botnick");
    if ($irc->is_channel_member($channel, $_)) {
      $irc->yield (mode => "$channel" => "$status" => "$_");
    }
  } 
}

sub pc_ban {
  my ($mode, $channel, $botnick, @args) = @_;
  if (! check_if_op($channel, $botnick)) {
    bot_says($channel, "I need op");
    return
  }
  foreach (@args) {
    next if ("$_" eq "$botnick");
    if ($irc->is_channel_member($channel, $_)) {
      my $whois = $irc->nick_info($_);
      my $host = $$whois{'Host'};
      $irc->yield (mode => "$channel" => "$mode" => "\*!\*\@$host");
    }
  } 
}

sub pc_kick {
  my ($nick, $target, $channel, $botnick, $reason) = @_;
  return if ("$target" eq "$botnick");
  if (! check_if_op($channel, $botnick)) {
    bot_says($channel, "I need op");
    return
  }
  if ($irc->is_channel_member($channel, $target)) {
    if ($reason) {
      my $message = $reason.' ('.$nick.')';
      $irc->yield (kick => "$channel" => "$target" => "$message");
    } else {
      my $message = 'no reason given'.' ('.$nick.')';
      $irc->yield (kick => "$channel" => "$target" => "$message");
    }
  }
}


sub irc_botcmd_mode {
  my ($who, $channel, $mode) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  return unless (check_if_admin($who));
  if (! check_if_op($channel, $botnick)) {
    bot_says($channel, "I need op");
    return
  }
  $irc->yield (mode => "$channel" => "$mode");
}

sub irc_botcmd_topic {
  my ($who, $channel, $topic) = @_[ARG0..$#_];
  my $nick = parse_user($who);
  my $botnick = $irc->nick_name;
  if (! check_if_op($channel, $botnick)) {
    bot_says($channel, "I need op");
    return
  }
  if ((! $topic) or ($topic =~ m/^\s*$/)) {
    bot_says($channel, 'Missing argument (the actual topic to set)');
  } else {
    return unless (check_if_op($channel, $nick)) || (check_if_admin($who));
    $irc->yield (topic => "$channel" => "$topic");
  }
}

## Game: Timebomb

my %defuse;
my %bomb_active;

sub irc_botcmd_timebomb {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  my @args = split(/ +/, $what);
  my $target = shift(@args);
  my @colors = ('red', 'yellow', 'blue', 'brown', 'pink', 'green', 'gold', 'magenta', 'orange', 'beige', 'black', 'grey', 'lime', 'navy');
  my @wires;
  while (@wires <= 3) {
    my $lenght = scalar @colors;
    my $random = int(rand($lenght));
    my $wire = splice(@colors,$random,1);
    push @wires,$wire;
  }
  if (! check_if_op($channel, $botnick)) {
    bot_says($channel, "op me first; You know, just in case ;)");
    return
  }
  if ($target eq $botnick) {
    bot_says($channel, "$nick: you mad bro?!");
    return;
  } else {
    if ($irc->is_channel_member($channel, $target)) {
      bot_says($channel, "$nick slips a bomb on $target\'s panties: the display reads \"$bbold@wires$ebold\"; $target: which wire would you like to cut to defuse the bomb? You have about 20 secs left..");
      my $lenght = scalar @wires;
      my $random = int(rand($lenght));
      $defuse{$channel} = $wires[$random];
      $bomb_active{$channel} = 1;
      my $reason = "Booom!";
      $kernel->delay_set("timebomb_start", 20, $target, $channel, $botnick, $reason);
      my $tic = 12;
      $kernel->delay_set("timebomb_check", 7, $channel, $tic);
      $tic = 5;
      $kernel->delay_set("timebomb_check", 15, $channel, $tic);
    }
  }
}

sub timebomb_start {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my ($target, $channel, $botnick, $reason) = @_[ARG0..$#_];
  if (defined $bomb_active{$channel}) {
    pc_kick($botnick, $target, $channel, $botnick, $reason);
    undef $bomb_active{$channel};
    undef $defuse{$channel};
    return;
  }
}


sub irc_botcmd_cut {
  my ($who, $channel, $what) = @_[ARG0..$#_];
  my $botnick = $irc->nick_name;
  my $nick = parse_user($who);
  my @args = split(/ +/, $what);
  my $wire = shift(@args);
  return unless (defined $defuse{$channel});
  if ($wire eq $defuse{$channel}) {
    undef $bomb_active{$channel};
    undef $defuse{$channel};
    bot_says($channel, "Congrats $nick, bomb defused.");
    return
  } else {
    my $target = $nick;
    my $reason = "Booom!";
    pc_kick($botnick, $target, $channel, $botnick, $reason);
    undef $bomb_active{$channel};
    undef $defuse{$channel};
  }
}

sub timebomb_check {
  my ($kernel, $sender) = @_[KERNEL, SENDER];
  my ($channel, $tic) = @_[ARG0, ARG1];
  if (defined $bomb_active{$channel}) {
    bot_says($channel, "\(\-$tic\) ..tic tac..");
    return
  }
}


$dbh->disconnect;
exit;


