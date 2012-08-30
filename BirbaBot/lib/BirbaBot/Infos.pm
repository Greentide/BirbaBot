# -*- mode: cperl -*-

package BirbaBot::Infos;

use 5.010001;
use strict;
use warnings;
use DBI;
use Data::Dumper;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

our @EXPORT_OK = qw(kw_add kw_new kw_query kw_remove kw_list kw_find kw_show kw_delete_item karma_manage);

our $VERSION = '0.01';

sub kw_new {
  my ($dbname, $who, $key, $value) = @_;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');

  my $query = $dbh->prepare("INSERT INTO factoids (nick, key, bar1) VALUES (?, ?, ?);"); #nick, key, value1
  $query->execute($who, $key, $value);
  my $reply;
  if ($query->err) {
    my $errorcode = $query->err;
    if ($errorcode ==  19) {
      $reply = "I couldn't insert $value, $key already present"
    } else {
      $reply = "Unknow db error, returned $errorcode"
    }
  } else {
    $reply = "Okki"
  }
  $dbh->disconnect;
  return $reply;
}

sub kw_add {
  my ($dbname, $who, $key, $value) = @_;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $query = $dbh->prepare("UPDATE factoids SET bar2 = CASE WHEN bar2 IS NULL THEN ? WHEN bar2 IS NOT NULL THEN (SELECT bar2 FROM factoids where key = ?) END, bar3 = CASE WHEN bar2 IS NOT NULL AND bar3 IS NULL THEN ? WHEN bar2 IS NULL THEN (SELECT bar3 FROM factoids where key = ?) WHEN bar3 IS NOT NULL THEN (SELECT bar3 FROM factoids where key = ?) END WHERE key = ?;"); #bar2, bar3, key
  $query->execute($value, $key, $value, $key, $key, $key);
  $dbh->disconnect;
  return "Added $value to $key"
}

sub kw_remove {
  my ($dbname, $who, $key) = @_;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $del = $dbh->prepare("DELETE FROM factoids WHERE key=?;"); #key
  my $query = $dbh->prepare("SELECT key FROM factoids WHERE key=?;"); #key
  $query->execute($key);
  my $value = ($query->fetchrow_array());
  if (($value) && ($value eq $key)) { 
    $del->execute($key);
    $dbh->disconnect;
    return "I completely forgot $key";
  } else { 
    return "Sorry, dunno about $key"; 
    $dbh->disconnect;
  }
}

sub kw_delete_item {
  my ($dbname, $key, $position) = @_;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $check;
  if ($position == 2) {
    $check = $dbh->prepare("SELECT bar2 FROM factoids WHERE key = ? ;");
  } elsif ($position == 3) {
    $check = $dbh->prepare("SELECT bar3 FROM factoids WHERE key = ? ;");
  }
  $check->execute($key);
  my $value = ($check->fetchrow_array())[0];
  return "I don't have any definition of $key on the $position slot" unless $value;

  my $query;
  if ($position == 2) {
    $query = $dbh->prepare("UPDATE factoids SET bar2 = NULL WHERE key = ? ;");
  } elsif ($position == 3) {
    $query = $dbh->prepare("UPDATE factoids SET bar3 = NULL WHERE key = ? ;");
  }
  $query->execute($key);
  $dbh->disconnect;
  return "I forgot that $key is $value";
}

sub kw_query {
  my ($dbname, $nick, $key) = @_;
  my $questionkey = $key . '?';
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $query = $dbh->prepare("SELECT bar1,bar2,bar3 FROM factoids 
                             WHERE key = ? OR key = ?;");
  $query->execute($key, $questionkey);
  # here we get the results
  my @out;
  my $redirect;

  while (my @data = $query->fetchrow_array()) {
    foreach my $result (@data) {
      if ($result) {
	push @out, $result 
      }
    }
  }
  return unless @out;

  if (scalar @out == 1) {
    my @possibilities;
    if ($out[0] =~ m/\|\|/) {
      @possibilities= split (/\|\|/, $out[0]);
    }
    elsif ($out[0] =~ m/^\s*(<reply>)?\s*\((.+\|.+)\)\s*$/i) {
      my $possibilities_string = $2;
      @possibilities = split (/\|/, $possibilities_string);
    }
    if (scalar @possibilities > 1) {
      my $number = scalar @possibilities;
      my $random = int(rand($number));
      $out[0] = $possibilities[$random];
    }
    while ($out[0] =~ m/^\s*(<reply>){1}\s*see\s+(.+)$/i) {
      $redirect = $2;
      if ("$key" eq "$redirect") {
	my $egg2 = "Congratulations $nick, you've just discovered egg #2! ";
	my $bad = "I foresee two possibilities. One, coming face to face with herself 30 years older would put her into shock and she'd simply pass out. Or two, the encounter could create a time paradox, the results of which could cause a chain reaction that would unravel the very fabric of the space time continuum, and destroy the entire universe! Granted, that's a worse case scenario. The destruction might in fact be very localized, limited to merely our own galaxy. [doc]";
	return "$egg2"."$bad";
      } else {
	my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
	$dbh->do('PRAGMA foreign_keys = ON;');
	my $queryn = $dbh->prepare("SELECT bar1 FROM factoids WHERE key=?;"); #key
	$queryn->execute($redirect);
	while (my @data = $queryn->fetchrow_array()) {
	  # here we process
	  return unless @data;
	  if (@data) {
	    $out[0] = $data[0];
	    $dbh->disconnect;
	  }
	}
      }
    }
    my $reply = $out[0];
    $reply =~ s/\$(who|nick)/$nick/gi;
    $reply =~ s/^\s*<action>/ACTION /i;
    $reply =~ s/^\s*<reply>\s*//i;
    return $reply;
  } else {
    return join(", or ", @out)
  }
}


sub kw_list {
  my ($dbname) = shift;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $query = $dbh->prepare("SELECT key FROM factoids;"); #key
  $query->execute();
  # here we get the results
  my @out;
  while (my @data = $query->fetchrow_array()) {
    foreach my $result (@data) {
      if ($result) {
        push @out, $result
      }
    }
  }
  $dbh->disconnect;
  if ((@out) && (scalar @out <= 50)) {
    my $output = "I know the following facts: " . join(", ", sort(@out));
    return $output;
  } elsif ((@out) && (scalar @out > 50)) {
    my @facts = @out[0..49];
    my $output = "I know too many facts to be all listed: " . join(", ", (sort @facts)) . "...";
    return $output;
  } else { return "Dunno about any fact; empty list." }
}

sub kw_find {
  my ($dbname, $arg) = @_;
  my $like = "\%$arg\%";
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $query = $dbh->prepare("SELECT key FROM factoids WHERE key LIKE ? ;"); #key
  $query->execute($like);
  # here we get the results
  my @out;
  while (my @data = $query->fetchrow_array()) {
    foreach my $result (@data) {
      if ($result) {
        push @out, $result
      }
    }
  }
  $dbh->disconnect;
  if (@out) {
    my $output = "I know the following facts: " . join(", ", sort(@out));
    return $output;
  } else { return "Dunno about any matching fact; empty list." }
}

sub kw_show {
  my ($dbname, $arg) = @_;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  my $query = $dbh->prepare("SELECT bar1,bar2,bar3 FROM factoids WHERE key = ? ;"); #key
  $query->execute($arg);
  my @out;
  while (my @data = $query->fetchrow_array()) {
    foreach my $result (@data) {
      if ($result) {
        push @out, $result
      }
    }
  }
  $dbh->disconnect;
  
  if ((scalar @out) == 1) {
    my $output = "keyword \"$arg\" has been stored with the following value: bar1 = $out[0]";
    return $output;
  } elsif ((scalar @out) == 2) {
    my $output = "keyword \"$arg\" has been stored with the following values: bar1 is = $out[0] and bar2 is = $out[1]";
    return $output;
  } elsif ((scalar @out) == 3) {
    my $output = "keyword \"$arg\" has been stored with the following values: bar1 is = $out[0], bar2 is = $out[1] and bar3 = $out[2]";
    return $output;
  } else { 
    return "I think there's no fact named \"$arg\".";
  }
}

sub karma_manage {
  my ($dbname, $nick, $action) = @_;
  # print "arguments for karma_manage: ", join(':', @_), "\n";
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
  $dbh->do('PRAGMA foreign_keys = ON;');
  unless ($nick) {
    my @reply;
    my $query = $dbh->prepare('SELECT nick, level FROM karma');
    $query->execute();
    while (my @data = $query->fetchrow_array()) {
      push @reply, $data[0] . " => " . $data[1];
    }
    $dbh->disconnect;
    # print "disconnected db";

    if ((@reply) && ((scalar @reply) <= 15)) {
      return join(", ", (sort @reply));
    } elsif ((@reply) && ((scalar @reply) > 15)) {
      my @karmas = join(", ", sort (@reply[0..15]));
      return "Too many karmas stored to be all printed: "."@karmas";
    } else { return "Karma list is empty." }
  }


  unless ($action) {
    my $query = $dbh->prepare('SELECT level FROM karma WHERE nick = ?;');
    $query->execute($nick);
    my $reply ;
    while (my @data = $query->fetchrow_array()) {
      $reply = $nick . " has karma " . $data[0];
    }
    $dbh->disconnect;
    # print "disconnected db";
    if ($reply) {
      return $reply;
    } else {
      return "No karma for $nick";
    }
  }

  my $oldkarma = $dbh->prepare('SELECT nick,level,last FROM karma WHERE nick = ?;');
  $oldkarma->execute($nick);
  my ($queriednick, $level, $lastupdate)  = $oldkarma->fetchrow_array();
  $oldkarma->finish();

  unless($queriednick) {
    my $insert = $dbh->prepare('INSERT INTO karma (nick, last, level) VALUES ( ?, ?, ?);');
    $insert->execute($nick, 0, 0);
    $level = 0;
    $lastupdate = 0;
  }

  my $currenttime = time();
  if (($currenttime - $lastupdate) < 60) {
    $dbh->disconnect;
    return "Karma for $nick updated less then one minute ago";
  }
  
  my $updatevalue = $dbh->prepare('UPDATE karma SET level = ?,last = ? where nick = ?;');
  
  if ($action eq '++') {
    $level++;
  } elsif ($action eq '--') {
    $level--;
  }
  
  $updatevalue->execute($level, $currenttime, $nick);
  $dbh->disconnect;
  return "Karma for $nick is now $level";
}

1;
