use strict;
use warnings;

our $VERSION = '0.2.7-test';
our %IRSSI = (
    authors	=> 'Nei',
    name	=> 'nickcolor_expando',
    description	=> 'colourise nicks',
    license	=> 'GPL v2',
   );

# inspired by bc-bd's nm.pl and mrwright's nickcolor.pl

# Usage
# =====
# after loading the script, add the colour expando to the format
# (themes are not supported)
#
#   /format pubmsg {pubmsgnick $2 {pubnick $nickcolor$0}}$1
#
# alternatively, use it together with nm2 script

# Options
# =======
# /set neat_colors <list of colours>
# * the list of colours for automatic colouring (you can edit it more
#   conveniently with /neatcolor colors)
#
# /set neat_ignorechars <regex>
# * regular expression of characters to remove from nick before
#   calculating the hash function
#
# /set neat_color_reassign_time <time>
# * if the user has not spoken for so long, the assigned colour is
#   forgotten and another colour may be picked next time the user
#   speaks

# Commands
# ========
# /neatcolor
# * show the current colour distribution of nicks
#
# /neatcolor set [<network>/<#channel>] <nick> <colour>
# * set a fixed colour for nick
#
# /neatcolor reset [<network>/<#channel>] <nick>
# * remove a set colour of nick
#
# /neatcolor get [<network>/<#channel>] <nick>
# * query the current or set colour of nick
#
# /neatcolor re [<network>/<#channel>] <nick>
# * force change the colour of nick to a random other colour (to
#   manually resolve clashes)
#
# /neatcolor save
# * save the colours to ~/.irssi/saved_nick_colors
#
# /neatcolor reset --all
# * re-set all colours
#
# /neatcolor colors
# * show currently configured colours, in colour
#
# /neatcolor colors add <list of colours>
# /neatcolor colors remove <list of colours>
# * add or remove these colours from the neat_colors setting


use Hash::Util qw(lock_keys);
use Irssi;


{ package Irssi::Nick }

my (%set_colour, %avoid_colour, %has_colour, %last_time, %netchan_hist);
my ($expando, $ignore_re, $ignore_setting, $retain_colour_time, @colours, $exited, $session_load_time);

# the numbers for the scoring system, highest colour value will be chosen
my %scores = (
    set => 10,
    keep => 5,
    global => 4,
    hash => 3,

    avoid => -20,
    hist => -10,
    used => -2,
   );
lock_keys(%scores);

my $history_lines = 40;
my $global_mode = 1; # start out with global nick colour

my @colour_bags = (
    [qw[20 30 40 50 04 66 0C 61 60 67 6L]], # RED
    [qw[37 3D 36 4C 46 5C 56 6C 6J 47 5D 6K 6D 57 6E 5E 4E 4K 4J 5J 4D 5K 6R]], # ORANGE
    [qw[3C 4I 5I 6O 6I 06 4O 5O 3U 0E 5U 6U 6V 6P 6Q 6W 5P 4P 4V 4W 5W 4Q 5Q 5R 6Y 6X]], # YELLOW
    [qw[26 2D 2C 3I 3O 4U 5V 2J 3V 3P 3J 5X]], # YELLOW-GREEN
    [qw[16 1C 2I 2U 2O 1I 1O 1V 1P 02 0A 1U 2V 4X]], # GREEN
    [qw[1D 1J 1Q 1W 1X 2Y 2S 2R 3Y 3Z 3S 3R 2K 3K 4S 5Z 5Y 4R 3Q 2Q 2X 2W 3X 3W 2P 4Y]], # GREEN-TURQUOIS
    [qw[17 1E 1L 1K 1R 1S 03 1M 1N 1T 0B 1Y 1Z 2Z 4Z]], # TURQUOIS
    [qw[28 2E 18 1F 19 1G 1A 1B 1H 2N 2H 09 3H 3N 2T 3T 2M 2G 2A 2F 2L 3L 3F 4M 3M 3G 29 4T 5T]], # LIGHT-BLUE
    [qw[11 12 23 25 24 13 14 01 15 2B 4N]], # DARK-BLUE
    [qw[22 33 44 0D 45 5B 6A 5A 5H 3B 4H 3A 4G 39 4F 6S 6T 5L 5N]], # VIOLET
    [qw[21 32 42 53 63 52 43 34 35 55 65 6B 4B 4A 48 5G 6H 5M 6M 6N]], # PINK
    [qw[38 31 05 64 54 41 51 62 69 68 59 5F 6F 58 49 6G]], # ROSE
    [qw[7A 00 10 7B 7C 7D 7E 7G 7F]], # DARK-GRAY
    [qw[7H 7I 27 7K 7J 08 7L 3E 7O 7Q 7N 7M 7P]], # GRAY
    [qw[7S 7T 7R 4L 7W 7U 7V 5S 07 7X 6Z 0F]], # LIGHT-GRAY
   );
my %colour_bags;
{ my $idx = 0;
  for my $bag (@colour_bags) {
      @colour_bags{ @$bag } = ($idx)x@$bag;
  }
  continue {
      ++$idx;
  }
}
my @colour_list = map { @$_ } @colour_bags;
my @bases = split //, 'kbgcrmywKBGCRMYW04261537';
my %base_map = map { $bases[$_] => sprintf '%02X', ($_ % 0x10) } 0..$#bases;
my %ext_to_base_map = map { (sprintf '%02X', $_) => $bases[$_] } 0..15;

sub expando_neatcolour {
    return $expando;
}

# one-at-a-time hash
sub simple_hash {
    use integer;
    my $hash = 0x5065526c + length $_[0];
    for my $ord (unpack 'U*', $_[0]) {
	$hash += $ord;
	$hash += $hash << 10;
	$hash &= 0xffffffff;
	$hash ^= $hash >> 6;
    }
    $hash += $hash << 3;
    $hash &= 0xffffffff;
    $hash ^= $hash >> 11;
    $hash = $hash + ($hash << 15);
    $hash &= 0xffffffff;
}

{ my %lut1;
  my @z = (0 .. 9, 'A' .. 'Z');
  for my $x (16..255) {
      my $idx = $x - 16;
      my $col = 1+int($idx / @z);
      $lut1{ $col . @z[(($col > 6 ? 10 : 0) + $idx) % @z] } = $x;
  }
  for my $idx (0..15) {
      $lut1{ (sprintf "%02X", $idx) } = ($idx&8) | ($idx&4)>>2 | ($idx&2) | ($idx&1)<<2;
  }

  sub debug_ansicolour {
      my ($col, $bg) = @_;
      return '' unless defined $col && exists $lut1{$col};
      $bg = $bg ? 48 : 38;
      "\e[$bg;5;$lut1{$col}m"
  }
}
sub debug_colour {
    my ($col, $bg) = @_;
    defined $col ? (debug_ansicolour($col, $bg) . $col . "\e[0m") : '(none)'
}
sub debug_score {
    my ($score) = @_;
    if ($score == 0) {
	return $score
    }
    my @scale = $score > 0 ? (qw(16 1C 1I 1U 2V 4X)) : (qw(20 30 40 60 67 6L));;
    my $v = (log 1+ abs $score)*(log 20);
    debug_ansicolour($scale[$v >= $#scale ? -1 : $v], 1) . $score . "\e[0m"
}
sub debug_reused {
    my ($netchan, $nick, $col) = @_;
    my $chc = simple_hash($netchan);
    my $hashcolour = @colours ? $colours[ $chc % @colours ] : 0;
}
sub debug_scores {
    my ($netchan, $nick, $col, $prios, $colours) = @_;
    my $inprogress;
    unless (ref $prios) {
	$inprogress = $prios;
	$prios = [ sort { $colours->{$b} <=> $colours->{$a} } grep { exists $colours->{$_} } @colour_list ];
    }
    my $chc = simple_hash($netchan);
    my $hashcolour = @colours ? $colours[ $chc % @colours ] : 0;
    unless ($inprogress) {
    }
    else {
    }
    for my $i (0..$#$prios) {
    }
}

sub colourise_nt {
    my ($netchan, $nick, $weak) = @_;
    my $time = time;

    my $old_colour = $has_colour{$netchan}{$nick};
    my $last_time = $last_time{$netchan}{$nick};

    my $keep_score = $weak ? $scores{keep} + $scores{set} : $scores{keep};

    unless ($weak) {
	$last_time{$netchan}{$nick}
	    = $last_time{''}{$nick} = $time;
    }
    else {
	$last_time{$netchan}{$nick} ||= 0;
    }

    my $colour;
    if (defined $old_colour && ($weak || (defined $last_time
	    && $last_time + $retain_colour_time > $time))) {
	$colour = $old_colour;
    }
    else {
	# search for a suitable colour
	my %colours = map { $_ => 0 } @colours;
	my $hashnick = $nick;
	$hashnick =~ s/$ignore_re//g if length $ignore_re;
	my $hash = simple_hash($global_mode ? "/$hashnick" : "$netchan/$hashnick");

	if (exists $set_colour{$netchan} && exists $set_colour{$netchan}{$nick}) {
	    $colours{ $set_colour{$netchan}{$nick} } += $scores{set};
	}
	elsif (exists $set_colour{''} && exists $set_colour{''}{$nick}) {
	    $colours{ $set_colour{''}{$nick} } += $scores{set};
	}

	if (exists $avoid_colour{$netchan} && exists $avoid_colour{$netchan}{$nick}) {
	    for (@{ $avoid_colour{$netchan}{$nick} }) {
		$colours{ $_ } += $scores{avoid} if exists $colours{ $_ };
	    }
	}

	if (defined $old_colour) {
	    $colours{$old_colour} += $keep_score
		if exists $colours{$old_colour};
	}
	elsif (exists $has_colour{''}{$nick}) {
	    $colours{ $has_colour{''}{$nick} } += $scores{global}
		if exists $colours{ $has_colour{''}{$nick} };
	}

	if (@colours) {
	    my $hashcolour = $colours[ $hash % @colours ];
	    if (!defined $old_colour || $hashcolour ne $old_colour) {
		$colours{ $hashcolour } += $scores{hash};
	    }
	}

	{ my @netchans = $global_mode ? keys %has_colour : $netchan;
	  my $total;
	  my %colour_pens;
	  for my $gnc (@netchans) {
	      for my $onick (keys %{ $has_colour{$gnc} }) {
		  next if $gnc ne $netchan && exists $has_colour{$netchan}{$onick};
		  next unless exists $last_time{$gnc}{$onick};
		  if ($last_time{$gnc}{$onick} > $time + $retain_colour_time
		     || ($last_time{$gnc}{$onick} == 0 && $session_load_time + $retain_colour_time > $time)) {
		      if (exists $colours{ $has_colour{$gnc}{$onick} }) {
			  $colour_pens{ $has_colour{$gnc}{$onick} } += $scores{used};
			  ++$total;
		      }
		  }
	      }
	  }
	  for (keys %colour_pens) {
	      $colours{ $_ } += $colour_pens{ $_ } / $total * @colours
		  if @colours;
	  }
        }

	{ my $fac = 1;
	  for my $gnetchan ($netchan, '') {
	      my $idx = exp(-log($history_lines)/$scores{hist});
	      for my $hent (reverse @{ $netchan_hist{$gnetchan} // [] }) {
		  next unless defined $hent->[1];
		  if ($hent->[0] ne $nick) {
		      my $pen = 1;
		      $pen *= 3 if length $nick == length $hent->[0];
		      $pen *= 2 if (substr $nick, 0, 1) eq (substr $hent->[0], 0, 1)
			  || 1 == abs +(length $nick) - (length $hent->[0]);
		      $colours{ $hent->[1] } -= log($pen*$history_lines)/log($idx) / $fac
			  if exists $colours{ $hent->[1] };
		  }
		  ++$idx;
		  last if $idx > $history_lines;
	      }
	      ++$fac;
	  }
        }

	{ my %bag_pens;
	  for my $co (keys %colours) {
	      $bag_pens{ $colour_bags{$co} } -= $colours{$co}/2 if $colours{$co} < 0;
	  }
	  for my $bag (keys %bag_pens) {
	      for my $co (@{ $colour_bags[$bag] }) {
		  $colours{$co} -= $bag_pens{$bag} / @colours
		      if @colours && exists $colours{$co};
	      }
	  }
        }

	my @prio_colours = sort { $colours{$b} <=> $colours{$a} } grep { exists $colours{$_} } @colour_list;
	my $stop_at = 0;
	while ($stop_at < $#prio_colours
		   && $colours{ $prio_colours[$stop_at] } <= $colours{ $prio_colours[$stop_at + 1] }) {
	    ++$stop_at;
	}
	$colour = $prio_colours[ $hash % ($stop_at + 1) ]
	    if @prio_colours;

    }

    unless ($weak) {
	expire_hist($netchan, '');

	my $ent = [$nick, $colour];
	push @{ $netchan_hist{$netchan} }, $ent;
	push @{ $netchan_hist{''} }, $ent;
    }

    defined $colour ? ($has_colour{$netchan}{$nick} = $colour) : $colour
}

sub expire_hist {
    for my $ch (@_) {
	if ($netchan_hist{$ch}
		&& @{$netchan_hist{$ch}} > 2 * $history_lines) {
	    splice @{$netchan_hist{$ch}}, 0, $history_lines;
	}
    }
}

sub msg_line_tag {
    my ($srv, $msg, $nick, $addr, $targ) = @_;
    my $obj = $srv->channel_find($targ);
    clear_ref() && return unless $obj;
    my $nickobj = $obj->nick_find($nick);
    $nick = $nickobj->{nick} if $nickobj;
    my $colour = colourise_nt($srv->{tag}.'/'.$obj->{name}, $nick);
    $expando = $colour ? format_expand('%X'.$colour) : '';
}

sub msg_line_clear {
    clear_ref();
}

sub prnt_clear_public {
    my ($dest) = @_;
    clear_ref() if $dest->{level} & MSGLEVEL_PUBLIC;
}

sub clear_ref {
    $expando = '';
}

sub nicklist_changed {
    my ($chanobj, $nickobj, $old_nick) = @_;

    my $netchan = $chanobj->{server}{tag}.'/'.$chanobj->{name};
    my $nickstr = $nickobj->{nick};

    if (!exists $has_colour{''}{$nickstr} && exists $has_colour{''}{$old_nick}) {
	$has_colour{''}{$nickstr} = delete $has_colour{''}{$old_nick};
    }
    if (exists $has_colour{$netchan}{$old_nick}) {
	$has_colour{$netchan}{$nickstr} = delete $has_colour{$netchan}{$old_nick};
    }

    $last_time{$netchan}{$nickstr}
	= $last_time{''}{$nickstr} = time;

    for my $old_ent (@{ $netchan_hist{$netchan} }) {
	$old_ent->[0] = $nickstr if $old_ent->[0] eq $old_nick;
    }

}

{
    my %format2control = (
	'F' => "\cDa", '_' => "\cDc", '|' => "\cDe", '#' => "\cDi", "n" => "\cDg", "N" => "\cDg",
	'U' => "\c_", '8' => "\cV", 'I' => "\cDf",
       );
    my %bg_base = (
	'0'   => '0', '4' => '1', '2' => '2', '6' => '3', '1' => '4', '5' => '5', '3' => '6', '7' => '7',
	'x08' => '8', 'x09' => '9', 'x0a' => ':', 'x0b' => ';', 'x0c' => '<', 'x0d' => '=', 'x0e' => '>', 'x0f' => '?',
       );
    my %fg_base = (
	'k' => '0', 'b' => '1', 'g' => '2', 'c' => '3', 'r' => '4', 'm' => '5', 'p' => '5', 'y' => '6', 'w' => '7',
	'K' => '8', 'B' => '9', 'G' => ':', 'C' => ';', 'R' => '<', 'M' => '=', 'P' => '=', 'Y' => '>', 'W' => '?',
       );
    my @ext_colour_off = (
	'.', '-', ',',
	'+', "'", '&',
       );
    sub format_expand {
	$_[0] =~ s{%(Z.{6}|z.{6}|X..|x..|.)}{
	    my $c = $1;
	    if (exists $format2control{$c}) {
		$format2control{$c}
	    }
	    elsif (exists $bg_base{$c}) {
		"\cD/$bg_base{$c}"
	    }
	    elsif (exists $fg_base{$c}) {
		"\cD$fg_base{$c}/"
	    }
	    elsif ($c =~ /^[{}%]$/) {
		$c
	    }
	    elsif ($c =~ /^(z|Z)([[:xdigit:]]{2})([[:xdigit:]]{2})([[:xdigit:]]{2})$/) {
		my $bg = $1 eq 'z';
		my (@rgb) = map { hex $_ } $2, $3, $4;
		my $x = $bg ? 0x1 : 0;
		my $out = "\cD" . (chr -13 + ord '0');
		for (my $i = 0; $i < 3; ++$i) {
		    if ($rgb[$i] > 0x20) {
			$out .= chr $rgb[$i];
		    }
		    else {
			$x |= 0x10 << $i; $out .= chr 0x20 + $rgb[$i];
		    }
		}
		$out .= chr 0x20 + $x;
		$out
	    }
	    elsif ($c =~ /^(x)(?:0([[:xdigit:]])|([1-6])(?:([0-9])|([a-z]))|7([a-x]))$/i) {
		my $bg = $1 eq 'x';
		my $col = defined $2 ? hex $2
		    : defined $6 ? 232 + (ord lc $6) - (ord 'a')
			: 16 + 36 * ($3 - 1) + (defined $4 ? $4 : 10 + (ord lc $5) - (ord 'a'));
		if ($col < 0x10) {
		    my $chr = chr $col + ord '0';
		    "\cD" . ($bg ? "/$chr" : "$chr/")
		}
		else {
		    "\cD" . $ext_colour_off[($col - 0x10) / 0x50 + $bg * 3] . chr (($col - 0x10) % 0x50 - 1 + ord '0')
		}
	    }
	    else {
		"%$c"
	    }
        }ger;
    }
}

sub save_colours {
    open my $fid, '>', Irssi::get_irssi_dir() . '/saved_nick_colors'
	or do {
	    Irssi::print("Error saving nick colours: $!", MSGLEVEL_CLIENTERROR)
		    unless $exited;
	    return;
	};

    local $\ = "\n";
    if (%set_colour) {
	print $fid '[set]';
	for my $netch (sort keys %set_colour) {
	    for my $nick (sort keys %{ $set_colour{$netch} }) {
		print $fid "$netch/$nick:".$set_colour{$netch}{$nick};
	    }
	}
	print $fid '';
    }
    my $time = time;
    print $fid '[session]';
    my %session_colour;
    for my $netch (sort keys %last_time) {
	for my $nick (sort keys %{ $last_time{$netch} }) {
	    if (exists $has_colour{$netch} && exists $has_colour{$netch}{$nick}
		    && ($last_time{$netch}{$nick} + $retain_colour_time > $time
		       || ($last_time{$netch}{$nick} == 0 && $session_load_time + $retain_colour_time > $time))) {
		$session_colour{$netch}{$nick} = $has_colour{$netch}{$nick};
		if (exists $session_colour{''}{$nick}) {
		    if (defined $session_colour{''}{$nick}
			    && $session_colour{''}{$nick} ne $session_colour{$netch}{$nick}) {
			$session_colour{''}{$nick} = undef;
		    }
		}
		else {
		    $session_colour{''}{$nick} = $session_colour{$netch}{$nick};
		}
	    }
	}
    }
    for my $nick (sort keys %{ $session_colour{''} }) {
	if (defined $session_colour{''}{$nick}) {
	    print $fid "/$nick:".$session_colour{''}{$nick};
	}
	else {
	    for my $netch (sort keys %session_colour) {
		print $fid "$netch/$nick:".$session_colour{$netch}{$nick}
		    if exists $session_colour{$netch}{$nick} && defined $session_colour{$netch}{$nick};
	    }
	}
    }

    close $fid;
}

sub load_colours {
    $session_load_time = time;

    open my $fid, '<', Irssi::get_irssi_dir() . '/saved_nick_colors'
	or return;
    my $mode;
    while (my $line = <$fid>) {
	chomp $line;
	if ($line =~ /^\[(.*)\]$/) {
	    $mode = $1;
	    next;
	}

	my $colon = rindex $line, ':';
	next if $colon < 0;
	my $slash = rindex $line, '/', $colon;
	next if $slash < 0;
	my $col = substr $line, $colon +1;
	next unless length $col;
	my $netch = substr $line, 0, $slash;
	my $nick = substr $line, $slash +1, $colon-$slash -1;
	if ($mode eq 'set') {
	    $set_colour{$netch}{$nick} = $col;
	}
	elsif ($mode eq 'session') {
	    $has_colour{$netch}{$nick} = $col;
	    $last_time{$netch}{$nick} = 0;
	}
    }
    close $fid;
}

sub UNLOAD {
    return if $exited;
    save_colours();
}

sub exit_save {
    $exited = 1;
    save_colours();
}

sub get_nick_color2 {
    my ($tag, $chan, $nick, $format) = @_;
    my $col = colourise_nt($tag.'/'.$chan, $nick, 1);
    $col ? $format ? format_expand('%X'.$col) : $col : ''
}

sub cmd_neatcolor_colors_add {
    my ($data, $server, $witem) = @_;
    my @add_colours = grep { defined && length } map {
	length == 1 ? $base_map{$_}
	    : length == 3 ? substr $_, 1
		: $_ } map { /(?|x(..)|([0-7].)|(.))/gi }
		    split ' ', $data;
    my @added;
    my %scolours = map { $_ => undef } @colours;
    for my $c (@add_colours) {
	if ((grep { $_ eq $c } @colour_list) && !exists $scolours{$c}) {
	    push @added, $c;
	    $scolours{$c} = undef;
	}
    }
    if (@added) {
	Irssi::settings_set_str('neat_colors', join '', map { $ext_to_base_map{$_} // "X$_" } grep { exists $scolours{$_} } @colour_list);
	Irssi::print("%_nce2%_: added ".(join ' ', map { "%X$_".($ext_to_base_map{$_} // "X$_").'%n' } @added)." to neat_colors", MSGLEVEL_CLIENTCRAP);
	setup_changed();
    }
    else {
	Irssi::print("%_nce2%_: nothing added", MSGLEVEL_CLIENTCRAP);
    }
}
sub cmd_neatcolor_colors_remove {
    my ($data, $server, $witem) = @_;
    my @rm_colours = grep { defined && length } map {
	length == 1 ? $base_map{$_}
	    : length == 3 ? substr $_, 1
		: $_ } map { /(?|x(..)|([0-7].)|(.))/gi }
		    split ' ', $data;
    my @removed;
    my %scolours = map { $_ => undef } @colours;
    for my $c (@rm_colours) {
	if ((grep { $_ eq $c } @colour_list) && exists $scolours{$c}) {
	    push @removed, $c;
	    delete $scolours{$c};
	}
    }
    if (@removed) {
	Irssi::settings_set_str('neat_colors', join '', map { $ext_to_base_map{$_} // "X$_" } grep { exists $scolours{$_} } @colour_list);
	Irssi::print("%_nce2%_: removed ".(join ' ', map { "%X$_".($ext_to_base_map{$_} // "X$_").'%n' } @removed)." from neat_colors", MSGLEVEL_CLIENTCRAP);
	setup_changed();
    }
    else {
	Irssi::print("%_nce2%_: nothing removed", MSGLEVEL_CLIENTCRAP);
    }
}

sub cmd_neatcolor_colors {
    my ($data, $server, $witem) = @_;
    $data =~ s/\s+$//;
    unless (length $data) {
	Irssi::print("%_nce2%_: current colours: ".(@colours ? (join ' ', map { "%X$_".($ext_to_base_map{$_} // "X$_") } @colours) : '(none)'));
    }
    Irssi::command_runsub('neatcolor colors', $data, $server, $witem);
}

sub cmd_neatcolor {
    my ($data, $server, $witem) = @_;
    $data =~ s/\s+$//;
    unless (length $data) {
	$witem ||= Irssi::active_win;
	my $time = time;
	my %distribution = map { $_ => 0 } @colours;
	for my $netch (keys %has_colour) {
	    next unless length $netch;
	    for my $nick (keys %{ $has_colour{$netch} }) {
		if (exists $last_time{$netch}{$nick}
			&& $last_time{$netch}{$nick} + $retain_colour_time > $time) {
		    $distribution{ $has_colour{$netch}{$nick} }++
		}
	    }
	}
	$witem->print('%_nce2%_ Colour distribution: '.
			  (join ', ',
			   map { "%X$_$_:$distribution{$_}" }
			       sort { $distribution{$b} <=> $distribution{$a} }
				   grep { exists $distribution{$_} } @colour_list), MSGLEVEL_CLIENTCRAP);
    }
    Irssi::command_runsub('neatcolor', $data, $server, $witem);
}

sub cmd_neatcolor_set {
    my ($data, $server, $witem) = @_;
    my @args = split ' ', $data;
    if (@args < 2) {
	Irssi::print('%_nce2%_: not enough arguments for neatcolor set', MSGLEVEL_CLIENTERROR);
	return;
    }
    my $netchan;
    if (ref $witem) {
	$netchan = $witem->{server}{tag}.'/'.$witem->{name};
    }
    my $nick;
    my $colour;
    if (@args < 3) {
	($nick, $colour) = @args;
    }
    else {
	($netchan, $nick, $colour) = @args;
    }
    unless (length $netchan) {
	Irssi::print('%_nce2%_: no network/channel argument given for neatcolor set, use / to set global colours', MSGLEVEL_CLIENTERROR);
	return;
    }
    $colour = $base_map{$colour} if length $colour == 1;
    $colour = substr $colour, 1 if length $colour == 3;
    unless (length $colour && grep { $_ eq $colour } @colour_list) {
	Irssi::print('%_nce2%_: no colour or invalid colour argument given for neatcolor set', MSGLEVEL_CLIENTERROR);
	return;
    }
    $set_colour{$netchan eq '/' ? '' : $netchan}{$nick} = $colour;
    for my $netch ($netchan eq '/' ? keys %has_colour : $netchan) {
	delete $has_colour{$netch}{$nick} unless
	    exists $has_colour{$netch}{$nick} && $has_colour{$netch}{$nick} eq $colour;
    }
    Irssi::print("%_nce2%_: %X$colour$nick%n colour set to: %X$colour$colour%n ".($netchan eq '/' ? 'globally' : "in $netchan"), MSGLEVEL_CLIENTCRAP);
}
sub cmd_neatcolor_get {
    my ($data, $server, $witem) = @_;
    my @args = split ' ', $data;
    if (@args < 1) {
	Irssi::print('%_nce2%_: not enough arguments for neatcolor get', MSGLEVEL_CLIENTERROR);
	return;
    }
    my $netchan;
    if (ref $witem) {
	$netchan = $witem->{server}{tag}.'/'.$witem->{name};
    }
    my $nick;
    if (@args < 2) {
	$nick = $args[0];
    }
    else {
	($netchan, $nick) = @args;
    }
    unless (length $netchan) {
	Irssi::print('%_nce2%_: no network/channel argument given for neatcolor get', MSGLEVEL_CLIENTERROR);
	return;
    }
    if ($netchan ne '/') {
	unless (exists $has_colour{$netchan} && exists $has_colour{$netchan}{$nick}) {
	    Irssi::print("%_nce2%_: $nick is not coloured (yet) in $netchan", MSGLEVEL_CLIENTCRAP);
	}
	else {
	    my $colour = $has_colour{$netchan}{$nick};
	    Irssi::print("%_nce2%_: %X$colour$nick%n has colour: %X$colour$colour%n in $netchan", MSGLEVEL_CLIENTCRAP);
	}
    }
    if (exists $set_colour{$netchan} && exists $set_colour{$netchan}{$nick}) {
	my $colour = $set_colour{$netchan}{$nick};
	Irssi::print("%_nce2%_: set colour for %X$colour$nick%n in $netchan: %X$colour$colour%n ", MSGLEVEL_CLIENTCRAP);
    }
    elsif (exists $set_colour{''} && exists $set_colour{''}{$nick}) {
	my $colour = $set_colour{$netchan}{$nick};
	Irssi::print("%_nce2%_: set colour for %X$colour$nick%n (global): %X$colour$colour%n ", MSGLEVEL_CLIENTCRAP);
    }
}
sub cmd_neatcolor_reset {
    my ($data, $server, $witem) = @_;
    my @args = split ' ', $data;
    if (@args < 1) {
	Irssi::print('%_nce2%_: not enough arguments for neatcolor reset', MSGLEVEL_CLIENTERROR);
	return;
    }
    my $netchan;
    if (ref $witem) {
	$netchan = $witem->{server}{tag}.'/'.$witem->{name};
    }
    my $nick;
    if (@args == 1 && $args[0] eq '--all') {
	%set_colour = %avoid_colour = %has_colour = ();
	Irssi::print("%_nce2%_: re-set all colouring");
	return;
    }
    if (@args < 2) {
	$nick = $args[0];
    }
    else {
	($netchan, $nick) = @args;
    }
    unless (length $netchan) {
	Irssi::print('%_nce2%_: no network/channel argument given for neatcolor reset', MSGLEVEL_CLIENTERROR);
	return;
    }
    unless (exists $set_colour{$netchan} && exists $set_colour{$netchan}{$nick}) {
	Irssi::print("%_nce2%_: $nick has no colour set in $netchan", MSGLEVEL_CLIENTERROR);
	return;
    }
    $netchan = '' if $netchan eq '/';
    my $colour = delete $set_colour{$netchan}{$nick};
    for my $netch ($netchan eq '' ? keys %has_colour : $netchan) {
	delete $has_colour{$netch}{$nick} if exists $has_colour{$netch} && exists $has_colour{$netch}{$nick}
	    && $has_colour{$netch}{$nick} eq $colour;
    }
    Irssi::print("%_nce2%_: ".($netchan eq '' ? 'global ' : '')."colouring re-set for $nick".($netchan eq '' ? '' : " in $netchan"), MSGLEVEL_CLIENTERROR);
}
sub cmd_neatcolor_re {
    my ($data, $server, $witem) = @_;
    my @args = split ' ', $data;
    if (@args < 1) {
	Irssi::print('%_nce2%_: not enough arguments for neatcolor re', MSGLEVEL_CLIENTERROR);
	return;
    }
    my $netchan;
    if (ref $witem) {
	$netchan = $witem->{server}{tag}.'/'.$witem->{name};
    }
    my $nick;
    if (@args < 2) {
	$nick = $args[0];
    }
    else {
	($netchan, $nick) = @args;
    }
    unless (length $netchan) {
	Irssi::print('%_nce2%_: no network/channel argument given for neatcolor re', MSGLEVEL_CLIENTERROR);
	return;
    }
    unless (exists $has_colour{$netchan} && exists $has_colour{$netchan}{$nick}) {
	Irssi::print("%_nce2%_: could not find $nick in $netchan", MSGLEVEL_CLIENTERROR);
	return;
    }
    my $colour = delete $has_colour{$netchan}{$nick};
    if (grep { $colour eq $_ } @{ $avoid_colour{$netchan}{$nick} || [] }) {
	$avoid_colour{$netchan}{$nick} = [ $colour ]
    }
    else {
	push @{ $avoid_colour{$netchan}{$nick} }, $colour;
    }
    Irssi::print("%_nce2%_: re-colouring $nick in $netchan", MSGLEVEL_CLIENTERROR);
}
sub cmd_neatcolor_save {
    Irssi::print("%_nce2%_: saving colours to file...", MSGLEVEL_CLIENTCRAP);
    save_colours();
}

sub setup_changed {
    $retain_colour_time = int( abs( Irssi::settings_get_time('neat_color_reassign_time') ) / 1000 );
    my $old_ignore = $ignore_setting // '';
    $ignore_setting = Irssi::settings_get_str('neat_ignorechars');
    if ($old_ignore ne $ignore_setting) {
	local $@;
	eval { $ignore_re = qr/$ignore_setting/ };
	if ($@) {
	    $@ =~ /^(.*)/;
	    print '%_neat_ignorechars%_ did not compile: '.$1;
	}
    }
    my $old_colours = "@colours";
    my %scolours = map { ($base_map{$_} // $_) => undef } Irssi::settings_get_str('neat_colors') =~ /(?|x(..)|(.))/ig;
    @colours = grep { exists $scolours{$_} } @colour_list;

    if ($old_colours ne "@colours") {
	my $time = time;
	for my $netch (sort keys %last_time) {
	    for my $nick (sort keys %{ $last_time{$netch} }) {
		if (exists $has_colour{$netch} && exists $has_colour{$netch}{$nick}) {
		    if ($last_time{$netch}{$nick} + $retain_colour_time > $time
			    || ($last_time{$netch}{$nick} == 0 && $session_load_time + $retain_colour_time > $time)) {
			$last_time{$netch}{$nick} = 0;
		    }
		    else {
			delete $last_time{$netch}{$nick};
		    }
		}
	    }
	    $session_load_time = $time;
	}
    }
}

sub internals {
    +{
	set	=> \%set_colour,
	avoid	=> \%avoid_colour,
	has	=> \%has_colour,
	time	=> \%last_time,
	hist	=> \%netchan_hist,
	colours	=> \@colours
       }
}

sub init_nickcolour {
    setup_changed();
    load_colours();
}

Irssi::settings_add_str('misc', 'neat_colors', 'rRgGybBmMcCX42X3AX5EX4NX3HX3CX32');
Irssi::settings_add_str('misc', 'neat_ignorechars', '');
Irssi::settings_add_time('misc', 'neat_color_reassign_time', '30min');
init_nickcolour();

Irssi::expando_create('nickcolor', \&expando_neatcolour, {
    'message public' 	 => 'none',
    'message own_public' => 'none'
   });

Irssi::signal_add({
    'message public'	 => 'msg_line_tag',
    'message own_public' => 'msg_line_clear',
    'print text'	 => 'prnt_clear_public',
    'nicklist changed' 	 => 'nicklist_changed',
    'gui exit'		 => 'exit_save',
});
Irssi::command_bind({
    'neatcolor'		      => 'cmd_neatcolor',
    'neatcolor save'	      => 'cmd_neatcolor_save',
    'neatcolor set'	      => 'cmd_neatcolor_set',
    'neatcolor get'	      => 'cmd_neatcolor_get',
    'neatcolor reset'	      => 'cmd_neatcolor_reset',
    'neatcolor re'	      => 'cmd_neatcolor_re',
    'neatcolor colors'	      => 'cmd_neatcolor_colors',
    'neatcolor colors add'    => 'cmd_neatcolor_colors_add',
    'neatcolor colors remove' => 'cmd_neatcolor_colors_remove',
  });

Irssi::signal_add_last('setup changed' => 'setup_changed');

