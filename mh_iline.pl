##############################################################################
#
# mh_iline.pl v0.04 (20170312)
#
# Copyright (c) 2017  Michael Hansen
#
# Permission to use, copy, modify, and distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice
# appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
# WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
# THE AUTHOR BE LIABLE FOR  ANY SPECIAL, DIRECT, INDIRECT, OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
# NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
##############################################################################
#
# IRC frontend to the https://i-line.space IRCnet I-line lookup service by pbl
#
# a lot of unfolding nested ifs/sub-ifying and corner case, error checking and
# cosmetic things and instructions/comments to do, but it works and with the
# limited documentation below you should be able to get it running :)
#
# at a minimum you need to set mh_iline_channels as explained under settings
#
# per default the client needs to be +v, +h or +o to monitor for commands, this can
# be disabled with /set mh_iline_require_privs off
#
# the default command !iline will react as follows:
#
#	!iline          | lookup ip of command issuer, this supports mibbit webchat users
#	!iline ip(4/6)  | lookup the given ip, ex: !iline 127.0.0.1
#	!iline nickname | lookup the given nicknames ip if it is on the channel, ex: !iline mh
#	                  (nickname requires the user is on the channel)
#
# the script also (optionally) supports !help and !version both without arguments
#
# The prefix codes means where the data/info comes from (eg [P]/[Public] means the IP was
# gotten from the requesters irc host, or for nicks from irssis internal nicklist)
#
# settings:
#
# mh_iline_channels (string, default: ''):
#	a comma-seperated list of Network/Channel to monitor for command
#	(ex. IRCnet/#i-line,IRCnet/#i-line2)
#
# mh_iline_command (string, default: 'Iline'):
#	name of command to monitor (prefixed by command_char)
#
# mh_iline_command_char (string, default: '!'):
#	command prefix character
#
# mh_iline_lag_limit (int, default: 5):
#	lag in seconds before we ignore any commands
#
# mh_iline_url (string, default: 'https://api.i-line.space/index.php?q='):
#	backend url to sent our requests to (argument is appended)
#
# mh_iline_require_privs (bool, default: on):
#	require +o, +v or +h to enable monitoring
#
# mh_iline_show_iline (bool, default: on):
#	show the [Iline] prefix on lines sent
#
# mh_iline_command_help (bool, default: on):
#	enable/disable !help support
#
# mh_iline_command_version (bool, default: on):
#	enable/disable !version support
#
# mh_iline_test_webchat (bool, default: on):
#	enable/disable looking up webchat hosts
#
# mh_iline_show_prefix_long (bool, default: on):
#	enable/disable showing prefix data in long format if enabled
#
# mh_iline_show_prefix (bool, default: on):
#	enable/disable showing prefix data (the [A]/[Argument] etc part)
#
# mh_iline_show_extended (bool, default: on):
#	enable/disable showing extended information in lines
#
# mh_iline_hide_processing (bool,  default: off):
#	dont show '...Processing...' lines at all
#
# mh_iline_hide_looking (bool,  default: off):
#	dont show '...looking up...' lines at all
#
# mh_iline_hide_looking_nicks (bool,  default: off):
#	dont show '...looking up...' for [N]/[Nick] when requested by another user (!iline <nick>)
#	(if _hide_looking is on, this setting is irrelevant (implied))
#
# mh_iline_flood_timeout (int,  default: 60):
#	allow _flood_count requests in _flood_timeout seconds
#
# mh_iline_flood_count (int,  default: 5):
#	allow _flood_count requests in _flood_timeout seconds
#
# history:
#
#	v0.04 (20170312)
#		dont show extended (host) info for PREFIX_ARGUMENT, it likely doesnt match
#		fixed double signal handlers
#		added _require_privs default 'on' info to documentation
#
#	v0.03 (20170312)
#		change [M]/[Message] to [P]/[Public] to account for nicks
#		cleaned up the bitmask parsing in send_line() and put short/long format in one array
#		added _show_extended and supporting code
#		added _hide_processing and supporting code
#		added _hide_looking and supporting code
#		added _hide_looking_nicks and supporting code
#		added simple flood protection via settings _flood_timeout and _flood_count
#
#	v0.02 (20170311)
#		use https instead of http when requesting lookup and changed the url
#		moved channel messages to send_line() instead of individual SAYs
#		added setting _show_iline and supporting code
#		added setting _command_help and supporting code
#		added setting _command_version and supporting code
#		added setting _test_webchat and supporting code
#		added setting _show_prefix and supporting code
#		added setting _show_prefix_long and supporting code
#
#	v0.01 (20170310)
#		initial concept test release
#

use v5.14.2;

use strict;

##############################################################################
#
# irssi head
#
##############################################################################

use Irssi 20100403;

{ package Irssi::Nick }

our $VERSION = '0.04';
our %IRSSI   =
(
	'name'        => 'mh_iline',
	'description' => 'IRC frontend to the https://i-line.space IRCnet I-line lookup service by pbl',
	'license'     => 'BSD',
	'authors'     => 'Michael Hansen',
	'contact'     => 'mh on IRCnet #help',
	'url'         => 'https://github.com/mh-source/irssi-scripts',
	'changed'     => 'Sun Mar 12 13:55:40 CET 2017',
);

##############################################################################
#
# global variables
#
##############################################################################

our $in_progress = 0;
our $in_progress_server;
our $in_progress_channel;
our $in_progress_nick;

use constant {
	PREFIX_NONE	           => 0,
	PREFIX_ARGUMENT        => 1,
	PREFIX_WEBCHAT         => 2,
	PREFIX_PUBLIC          => 4,
	PREFIX_STATSL          => 8,
	PREFIX_NICK            => 16,
	PREFIX_REPLY           => 32,
	PREFIX_ERROR           => 64,
	PREFIX_REPLY_TRUNCATED => 128,
	PREFIX_REPLY_GARBAGE   => 256,

	PREFIX_MAX             => 256,
};

our @prefix_array =
(
	'' , ''         ,
	'A', 'Argument' ,
	'W', 'Webchat'  ,
	'P', 'Public'   ,
	'L', 'Stats L'  ,
	'N', 'Nick'     ,
	'<', 'Reply'    ,
	'!', 'Error'    ,
	'T', 'Truncated',
	'G', 'Garbage'  ,
);

our $floodcount   = 0;
our $floodtimeout = 0;

##############################################################################
#
# common support functions
#
##############################################################################

sub is_odd
{
	my ($number) = @_;

	if ($number % 2 == 1)
	{
		return(1);
	}

	return(0);
}

sub trim_space
{
	my ($string) = @_;

	if (defined($string))
	{
		$string =~ s/^\s+//g;
		$string =~ s/\s+$//g;

	} else
	{
		$string = '';
	}

	return($string);
}

##############################################################################
#
# script functions
#
##############################################################################

sub lazy_is_webhost
{
	my ($data) = @_;

	if ($data)
	{
		if ($data =~ m/^.+\.mibbit\.com$/i)
		{
			return(1);
		}
	}

	return(0);
}

sub lazy_is_hexip
{
	my ($data) = @_;


	if ($data)
	{
		if ($data =~ m/^[~+\-^=]?[a-f0-9]{8}$/i)
		{
			return(1);
		}
	}

	return(0);
}

sub lazy_is_hostname
{
	my ($data) = @_;

	if ($data)
	{
		if ($data =~ m/^.+\.[a-z]+$/i)
		{
			return(1);
		}
	}

	return(0);
}

sub lazy_is_ip
{
	my ($data) = @_;

	if ($data)
	{
		if ($data =~ m/^([a-f0-9.:]){3,45}$/i)
		{
			if ($data =~ m/.*[.:].*/i) # require at least one . or : so DEAF is a nick, not an IP
			{
				if (not lazy_is_hostname($data))
				{
					return(1);
				}
			}
		}
	}

	return(0);
}

sub hex_to_ip
{
	my ($data) = @_;

	if ($data)
	{
		if ($data =~ m/^[~+\-^=]?([a-f0-9]{8})$/i)
		{
			$data = $1;

			my $oct1 = hex(substr($data, 0, 2));
			my $oct2 = hex(substr($data, 2, 2));
			my $oct3 = hex(substr($data, 4, 2));
			my $oct4 = hex(substr($data, 6, 2));

			return($oct1 . "." . $oct2 . "." . $oct3 . "." . $oct4);
		}
	}

	return('');
}

sub send_line
{
	my ($channel, $nickname, $data, $prefixbits) = @_;

	if (ref($channel) eq 'Irssi::Irc::Channel')
	{
		$data = trim_space($data);
		my $banner = $nickname . ': ';
		my $prefix = '';

		if (Irssi::settings_get_bool('mh_iline_show_prefix') and $prefixbits)
		{
			$prefixbits = int($prefixbits);

			if ($prefixbits)
			{
				my $prefix_id = 0;

				# even id is short version, uneven id is long version

				if (Irssi::settings_get_bool('mh_iline_show_prefix_long'))
				{
					$prefix_id++;
				}

				$prefix .= '[';

				my $prefixbit = 1;

				while ($prefixbit <= PREFIX_MAX)
				{
					$prefix_id += 2;
					if ($prefixbits & $prefixbit)
					{
						$prefix .= $prefix_array[$prefix_id];
						if (is_odd($prefix_id))
						{
							$prefix .= ' ';
						}
					}
					$prefixbit = $prefixbit << 1;
				}

				$prefix = trim_space($prefix);
				$prefix .= '] ';
			}
		}

		if (Irssi::settings_get_bool('mh_iline_show_iline'))
		{
			$banner .= '[' . trim_space(Irssi::settings_get_str('mh_iline_command')) . '] ';
		}

		$channel->command('SAY ' . $banner . $prefix . $data);

		return(1);
	}

	return(0);
}

sub pipe_read
{
	my ($readh, $pipetag, $servertag, $channelname, $nickname) = @{$_[0]};

	my $reply = '';

	my $read_brake = 3;

	while (my $line = <$readh>)
	{
		chomp($line);
		$line = trim_space($line);
		$reply = $reply . ' ' . $line;
		$read_brake--;
		if (not $read_brake)
		{
			break;
		}
	}

	$reply = trim_space($reply);

	close($readh);
	Irssi::input_remove($$pipetag);

	my $server = Irssi::server_find_tag($servertag);

	if ($server)
	{
		my $channel = $server->channel_find($channelname);

		if ($channel)
		{
			if ($reply ne '')
			{
				$reply =~ s/<\/?[a-z]+?>//ig; # no more html tags (but allow < >)
				$reply = trim_space($reply);

				my $prefix = PREFIX_REPLY;

				if (length($reply) > 300)
				{
					$reply = trim_space(substr($reply, 0, 300));
					$prefix += PREFIX_REPLY_TRUNCATED;
				}

				if ($reply !~ m/^[a-z0-9.:_\-<>,(\/) ]{1,300}$/i) 
				{
					$reply =~ s/[^a-z0-9.:_\-<>,(\/) ]*//ig;
					$reply = trim_space($reply);
					$prefix += PREFIX_REPLY_GARBAGE;
				}

				send_line($channel, $nickname, $reply, $prefix);

			} else {

				$reply = 'No reply';

				if (Irssi::settings_get_bool('mh_iline_show_extended'))
				{
					$reply .= ' (' . Irssi::settings_get_bool('mh_iline_url') . ')';
				}

				send_line($channel, $nickname, $reply, PREFIX_REPLY + PREFIX_ERROR);
			}
		}
	}

	$in_progress = 0;
}

sub get_ilines
{
	my ($servertag, $channelname, $nickname, $data) = @_;

	if (pipe(my $readh, my $writeh))
	{
		my $pid = fork();

		if ($pid > 0) 
		{
			# parent

			close($writeh);
			Irssi::pidwait_add($pid);

			my $server = Irssi::server_find_tag($servertag);

			if ($server)
			{
				my $channel = $server->channel_find($channelname);

				if ($channel)
				{
					my $pipetag;
					my @args = ($readh, \$pipetag, $servertag, $channelname, $nickname);
					$pipetag = Irssi::input_add(fileno($readh), Irssi::INPUT_READ, 'pipe_read', \@args);
				}
			}

		} else {

			# child

			use LWP::Simple;
			use POSIX;

			$data = Irssi::settings_get_str('mh_iline_url') . $data;

			my $reply = LWP::Simple::get($data);

			eval
			{
				print($writeh $reply);
				close($writeh);
			};

			POSIX::_exit(1);
		}
	}
}

##############################################################################
#
# irssi timeouts
#
##############################################################################

sub timeout_flood_reset
{
	$floodcount   = 0;
	$floodtimeout = 0;
}

##############################################################################
#
# irssi signal handlers
#
##############################################################################

sub signal_redir_event_211
{
	my ($server, $data, $sender) = @_;

	if (lc($server->{'tag'}) eq lc($in_progress_server))
	{
		my $channel = $server->channel_find($in_progress_channel);

		if ($channel)
		{
			$data =~ s/.*\[.*@(.*)\].*/$1/;
			$data = lc(trim_space($data));

			my $extended = '';

			if (Irssi::settings_get_bool('mh_iline_show_extended'))
			{
				my $nick = $channel->nick_find($in_progress_nick);

				if ($nick)
				{
					$extended = ' (' . $nick->{'nick'} . '!' . $nick->{'host'} . ')';

				} else {

					$extended = ' (' . $in_progress_nick . ' not found)';
				}
			}

			if (not lazy_is_ip($data))
			{
				send_line($channel, $in_progress_nick, 'You do not seem to have an IP' . $extended, PREFIX_ERROR);

			} else {

				if (not Irssi::settings_get_bool('mh_iline_hide_looking'))
				{
					send_line($channel, $in_progress_nick, 'Looking up ' . $data . $extended, PREFIX_STATSL);
				}
				get_ilines($in_progress_server, $in_progress_channel, $in_progress_nick, $data);
				return(1);
			}
		}

		$in_progress = 0;
	}
}

sub signal_redir_event_481
{
	my ($server, $data, $sender) = @_;

	$in_progress = 0;
}

sub signal_message_public_priority_low
{
	my ($server, $data, $nickname, $address, $target) = @_;

	if($in_progress)
	{
		if ($in_progress < 2) # 'just this once'-hack :)
		{
			return(0);
		}
	}

	if ($in_progress < 2) # 'just this once'-hack :)
	{
		my $lag_limit = Irssi::settings_get_int('mh_iline_lag_limit');

		if ($lag_limit)
		{
			$lag_limit = $lag_limit * 1000; # seconds to milliseconds

			if ($server->{'lag'} >= $lag_limit)
			{
				return(0);
			}
		}
	}

	my $servertag   = lc($server->{'tag'});
	my $channelname = lc($target);

	for my $serverchannel (split(',', Irssi::settings_get_str('mh_iline_channels')))
	{
		$serverchannel = lc(trim_space($serverchannel));

		if ($serverchannel eq $servertag . '/' . $channelname)
		{
			my $channel = $server->channel_find($channelname);

			if ($channel)
			{
				if (not $channel->{'synced'})
				{
					return(0);
				}

				if (Irssi::settings_get_bool('mh_iline_require_privs'))
				{
					my $selfnick = $channel->nick_find($server->{'nick'});

					if (not $selfnick)
					{
						last;
					}

					if (not ($selfnick->{'op'} or $selfnick->{'voice'} or $selfnick->{'halfop'}))
					{
						last;
					}
				}

				my $nick = $channel->nick_find($nickname);
				my $extended = '';

				if ($nick)
				{
					my $command_char = Irssi::settings_get_str('mh_iline_command_char');

					if ($data =~ s/^\Q$command_char\E//i)
					{
						if (not $floodtimeout)
						{
							my $timeout = Irssi::settings_get_int('mh_iline_flood_timeout');

							$timeout = int($timeout) * 1000; # timeout in seconds

							if (not $timeout)
							{
								$timeout = 60 * 1000; # fallback to 60 seconds
							}

							$floodtimeout = Irssi::timeout_add_once($timeout, 'timeout_flood_reset', undef);
							$floodcount = 1;

						} else {

							my $count = Irssi::settings_get_int('mh_iline_flood_count');

							$count = int($count);

							if (not $count)
							{
								$count = 5; # fallback to allow 5 requests
							}

							if ($floodcount > $count)
							{
								last;
							}
						}
						$floodcount++;

						(my $command, $data) = split(' ', $data, 2);
						$command = lc(trim_space($command));

						if ($command eq lc(trim_space(Irssi::settings_get_str('mh_iline_command'))))
						{
							$data = trim_space($data);
							my $extended = '';

							if (Irssi::settings_get_bool('mh_iline_show_extended'))
							{
								$extended = ' (' . $nickname . '!' . $address . ')';
							}

							if ($in_progress < 2) # 'just this once'-hack :)
							{
								if (not Irssi::settings_get_bool('mh_iline_hide_processing'))
								{
									send_line($channel, $nickname, 'Processing...');
								}
							}

							$in_progress = 1;
							$in_progress_server  = $servertag;
							$in_progress_channel = $channelname;
							$in_progress_nick    = $nickname;

							if ($data eq '')
							{
								(my $hexip, $data) = split ('@', $address, 2);

								if (Irssi::settings_get_bool('mh_iline_test_webchat'))
								{
									if (lazy_is_webhost($data))
									{
										if (lazy_is_hexip($hexip))
										{
											$hexip = hex_to_ip($hexip);

											if (lazy_is_ip($hexip))
											{
												if (not Irssi::settings_get_bool('mh_iline_hide_looking'))
												{
													send_line($channel, $nickname, 'Looking up ' . $hexip . $extended, PREFIX_WEBCHAT);
												}
												get_ilines($servertag, $channelname, $nickname, $hexip);
												last;
											}
										}
									}
								}

								if (lazy_is_ip($data))
								{
									$data = lc($data);
									if (not Irssi::settings_get_bool('mh_iline_hide_looking'))
									{
										send_line($channel, $nickname, 'Looking up ' . $data . $extended, PREFIX_PUBLIC);
									}
									get_ilines($servertag, $channelname, $nickname, $data);
									last;
								}

								$server->redirect_event('mh_iline stats L',
									1,         # count
									$nickname, # arg
									-1,        # remote
									'',        # failure signal
									{          # signals
										'event 211' => 'redir mh_iline event 211', # RPL_STATSLINKINFO
										'event 481' => 'redir mh_iline event 481', # ERR_NOPRIVILEGES
										''          => 'event empty',
									}
                        		);

								$server->send_raw('STATS L ' . $nickname);

							} else {

								$data = lc($data);

								if (not lazy_is_ip($data))
								{
									$nick = $channel->nick_find($data);

									if ($nick)
									{
										my $selfcommand = trim_space(Irssi::settings_get_str('mh_iline_command_char')) . trim_space(Irssi::settings_get_str('mh_iline_command'));

										if ($floodcount)
										{
											$floodcount--; # recursive request isnt counted in flood
										}

										if (lc($nick->{'nick'}) ne lc($nickname))
										{
											if ((not Irssi::settings_get_bool('mh_iline_hide_looking')) and (not Irssi::settings_get_bool('mh_iline_hide_looking_nicks')))
											{
												send_line($channel, $nickname, 'Looking up ' . $nick->{'nick'}, PREFIX_NICK);
											}
											$in_progress = 0;
											signal_message_public_priority_low($server, $selfcommand, $nick->{'nick'}, $nick->{'host'}, $target);
											last;
										}

										$in_progress = 2; # 'just this once'-hack :)
										signal_message_public_priority_low($server, $selfcommand, $nick->{'nick'}, $nick->{'host'}, $target);
										last;
									}

									send_line($channel, $nickname, 'Not an IP(4/6) address or nickname', PREFIX_ERROR);
									$in_progress = 0;
									last;
								}

								if (not Irssi::settings_get_bool('mh_iline_hide_looking'))
								{
									send_line($channel, $nickname, 'Looking up ' . $data, PREFIX_ARGUMENT);
								}
								get_ilines($servertag, $channelname, $nickname, $data);
							}

							last;
						}

						if (Irssi::settings_get_bool('mh_iline_command_help'))
						{
							if ($command eq 'help')
							{
								$command = lc(trim_space(Irssi::settings_get_str('mh_iline_command')));

								send_line($channel, $nickname, 'Commands: ' . $command_char . $command . ', ' . $command_char . 'help' . ' & ' . $command_char . 'version' );
								send_line($channel, $nickname, 'Syntax:   ' . $command_char . $command . ' [<IP(4/6)>|<nickname>]');
								last;
							}
						}

						if (Irssi::settings_get_bool('mh_iline_command_version'))
						{
							if ($command eq 'version')
							{
								send_line($channel, $nickname, 'mh_iline.pl v0.04 Copyright (C) 2017  Michael Hansen');
								send_line($channel, $nickname, 'IRC frontend to the https://i-line.space IRCnet I-line lookup service by pbl');
								send_line($channel, $nickname, 'Download for Irssi at https://github.com/mh-source/irssi-scripts');
								last;
							}
						}
					}
				}
			}

			last;
		}
	}
}

sub signal_message_own_public_priority_low
{
	my ($server, $data, $target) = @_;

	my $nickname = $server->{'nick'};
	my $address  = $server->{'userhost'};

	signal_message_public_priority_low($server, $data, $nickname, $address, $target);
}

##############################################################################
#
# script on load
#
##############################################################################

Irssi::settings_add_str('mh_iline', 'mh_iline_channels',            '');
Irssi::settings_add_str('mh_iline', 'mh_iline_command',             'Iline');
Irssi::settings_add_str('mh_iline', 'mh_iline_command_char',        '!');
Irssi::settings_add_int('mh_iline', 'mh_iline_lag_limit',           5);
Irssi::settings_add_str('mh_iline', 'mh_iline_url',                 'https://api.i-line.space/index.php?q=');
Irssi::settings_add_bool('mh_iline', 'mh_iline_require_privs',      1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_show_iline',         1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_command_help',       1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_command_version',    1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_test_webchat',       1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_show_prefix_long',   1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_show_prefix',        1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_show_extended',      1);
Irssi::settings_add_bool('mh_iline', 'mh_iline_hide_processing',    0);
Irssi::settings_add_bool('mh_iline', 'mh_iline_hide_looking',       0);
Irssi::settings_add_bool('mh_iline', 'mh_iline_hide_looking_nicks', 0);
Irssi::settings_add_int('mh_iline', 'mh_iline_flood_timeout',       60);
Irssi::settings_add_int('mh_iline', 'mh_iline_flood_count',         5);

Irssi::Irc::Server::redirect_register('mh_iline stats L',
    1, # remote
    0, # timeout
    {  # start signals
        'event 211' => -1, # RPL_STATSLINKINFO
        'event 481' => -1, # ERR_NOPRIVILEGES
    },
    {  # stop signals
        'event 219' => -1, # RPL_ENDOFSTATS end of stats
    },
    undef # optional signals
);

Irssi::signal_add('redir mh_iline event 211', 'signal_redir_event_211');
Irssi::signal_add('redir mh_iline event 481', 'signal_redir_event_481');
Irssi::signal_add_priority('message public', 'signal_message_public_priority_low', Irssi::SIGNAL_PRIORITY_LOW + 1);
Irssi::signal_add_priority('message own_public', 'signal_message_own_public_priority_low', Irssi::SIGNAL_PRIORITY_LOW + 1);

1;

##############################################################################
#
# eof mh_iline.pl
#
##############################################################################