use strict;
use warnings;
use Irssi;

our $VERSION = '1.0';
our %IRSSI = (
    authors     => 'Daniel Andersson',
    contact     => 'https://github.com/dandersson',
    name        => 'nicklist-tmux_auto_resize',
    description => 'Keeps a tmux pane at a certain size, even after terminal '.
                   'resize (for use with nicklist.pl)',
    license     => 'GNU GPL v2 or later',
    url         => 'https://github.com/dandersson',
);

Irssi::command_bind('help',
    sub {if ($_[0] =~ '^nicklist-tmux_auto_resize ?') {
            &sig_help; Irssi::signal_stop();}});

sub sig_help
{
    my $usage = <<USAGEEND;
NICKLIST-TMUX_AUTO_RESIZE  --  Automatically resizes nicklist.pl pane in tmux

USAGE
    Load script and have a tmux pane open. By default it then resizes
    automatically.

    /nicklist tmuxresize
         Resize the nicklist manually.

REQUIRES
    tmux

SETTINGS
    nicklist_tmux_auto_resize <bool>
        Activate automatic resizing on terminal size change.

    nicklist_tmux_pane_index <int>
        Pane index in irssi window. If nicklist is to the right and only two
        panes exist, this is '1'. For other cases, see (*).

ABOUT
    Started as an external shell script, but was easy to implement directly in
    Perl. I find it very useful.

    It would be nice if tmux implemented a command to resize a tmux pane
    directly to a given size, and/or start taking negative numbers as resize
    arguments.

NOTES
    (*):
        By default it assumes that the pane in question is right-aligned. To
        support left/up/down-aligned panes, some simple conditional cases needs
        to be defined in the script (specifically in &tmux_get_resize_option).
        Not in my current interest, but it should be simple.
USAGEEND
    Irssi::print($usage, MSGLEVEL_CLIENTCRAP);
}

# Script output formatting
Irssi::theme_register(['nicklist-tmux_auto_resize',
        '{line_start}{hilight '.$IRSSI{'name'}.':} $0']);

### Start internal variable declaration
my $tmux = '/usr/bin/tmux';
sub first_line{ return substr($_[0], 0, index($_[0], "\n")) }
my $tmux_session_window = &first_line(
    qx/$tmux list-windows -F '#{session_name}'/).':'.&first_line(
    qx/$tmux list-panes -F '#{window_index}'/);
my $current_width;
my $current_height;
### End internal variable declaration

### Start external settings handling
Irssi::settings_add_bool('nicklist-tmux_auto_resize',
    'nicklist_tmux_auto_resize', 1);
Irssi::settings_add_int ('nicklist-tmux_auto_resize',
    'nicklist_tmux_pane_index', 1);

my $nicklist_tmux_auto_resize;
my $nicklist_tmux_pane_index;
my $awl_resize;
# $nicklist_height not yet needed since only right-alignment is considered.

sub load_settings
{
    $nicklist_tmux_auto_resize = Irssi::settings_get_bool(
        'nicklist_tmux_auto_resize');
    $nicklist_tmux_pane_index = Irssi::settings_get_int(
        'nicklist_tmux_pane_index');
    $awl_resize = Irssi::settings_get_int('awl_block');
    unless ($awl_resize > 0) {
        Irssi::printformat(MSGLEVEL_CLIENTNOTICE, 'nicklist-tmux_auto_resize',
            'You need to set nicklist_width >0 to be able to resize the pane');
        return;
    }
    # $nicklist_height not yet needed since only right-alignment is considered.

    # Could make the below call dependant on whether the settings have actually
    # changed or not, but irssi does not provide such a signal and it is much
    # coding for in practice almost no gain, so just resize it if auto-resizing
    # is enabled.
    &tmux_resize_nicklist if $nicklist_tmux_auto_resize;
}

# I need to wait for nicklist_width from nicklist.pl to be set. Without the
# below timeout, the script will fail on autoload with
# -!- Irssi: warning settings_get(nicklist_width) : not found
# even though the setting exists in '~/.irssi/config'.
Irssi::timeout_add_once(10, \&load_settings, undef);

Irssi::signal_add('setup changed', \&sig_setup_changed);
sub sig_setup_changed
{
    &load_settings;
}
### End external settings handling

sub sig_terminal_resized
{
    &tmux_resize_nicklist if $nicklist_tmux_auto_resize;
}


sub tmux_resize_nicklist
{
    system($tmux, '-q', 'resize-pane', '-t', '0',
        '-x', $awl_resize);
}

Irssi::command_bind('nicklist tmuxresize',\&tmux_resize_nicklist);
Irssi::signal_add('terminal resized', \&sig_terminal_resized);
