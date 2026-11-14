#!/usr/bin/perl -w
#
# NetScaler-SMTP-Monitor.pl - extended SMTP user monitor for NetScaler (KAS)
#
# Checks that an SMTP server is alive. Compared to the stock nssmtp.pl it can
# optionally
#   * send a PROXY protocol header, version 1 or 2 (for backends that expect it),
#   * talk TLS: STARTTLS (port 25/587) or implicit TLS (port 465),
#   * run an SMTP transaction test (EHLO, MAIL FROM, RCPT TO) to verify that
#     the server accepts a sender and recipient. DATA is never sent, so no
#     message is ever delivered or queued,
#   * treat temporary failures (4xx, e.g. greylisting) as "server is alive",
#   * check the banner against a regular expression,
#   * mark the service DOWN when the answer takes too long,
#   * write a step-by-step debug log for troubleshooting.
#
# With the default settings below it behaves like a plain "connect and wait
# for the 220 banner" check. See README.md and QUICKSTART.md.
#
# Version 1.0.0 - released under the MIT License (see LICENSE).
# Not affiliated with or endorsed by Cloud Software Group, Inc. / Citrix.

use strict;
use IO::Socket::INET;
use IO::Select;
use Fcntl qw(:flock);
use Socket ();
use lib '/netscaler/monitors/perl_mod';
$ENV{"nsumon_resptout"} //= 5000;    # default response timeout (ms) for the KAS framework
use Netscaler::KAS;

# Optional modules: only needed for IPv6 targets / TLS modes / high-resolution timer
my $have_inet6 = eval { require IO::Socket::INET6; 1 };
my $have_ssl   = eval { require IO::Socket::SSL;   1 };
my $have_hires = eval { require Time::HiRes;       1 };

################################################################################
## Configuration - edit this section only
##
## Every setting is one line "my $NAME = value;". Text values are in quotes.
## In double quotes the @ sign MUST be escaped with a backslash, e.g.
## "monitor\@example.com", otherwise the script does not compile. In single
## quotes no escaping is needed: 'monitor@example.com'.
################################################################################

# Transport security:
#   plain    - clear text, no encryption (typical for port 25)
#   starttls - clear text first, then upgrade with STARTTLS (port 25 / 587)
#   tls      - TLS from the first byte, "implicit TLS" / SMTPS (port 465)
my $TLS_MODE = "plain";

# PROXY protocol header, sent as the very first bytes on the connection (before
# the TLS handshake). Enable it only if the backend expects it, e.g. Postfix
# with smtpd_upstream_proxy_protocol / postscreen_upstream_proxy_protocol =
# haproxy. A server that does not expect the header will reject the monitor.
#   0 = off, 1 = version 1 (text), 2 = version 2 (binary)
my $PROXY_PROTOCOL = 0;

# SMTP transaction test. 1 = after EHLO send MAIL FROM and RCPT TO and require
# that the server accepts both, then RSET and QUIT. DATA is never sent, so no
# mail is delivered. 0 = only check banner (and STARTTLS if configured).
my $MAIL_TEST = 0;
my $MAIL_FROM = "";    # sender address,    required if $MAIL_TEST = 1
my $RCPT_TO   = "";    # recipient address, required if $MAIL_TEST = 1

# Temporary failures during the mail test. Servers with greylisting or
# postscreen often answer MAIL FROM / RCPT TO with a 4xx code (e.g. 450) to
# clients they do not know yet. 1 = treat a 4xx answer as "server is alive"
# (the transaction is then not verified further), 0 = any 4xx means DOWN.
my $ACCEPT_TEMP_FAIL = 0;

# Name announced in EHLO. Leave empty to use the monitor's own IP address as
# address literal, e.g. [192.0.2.10] (valid per RFC 5321).
my $EHLO_DOMAIN = "";

# Optional server name sent as SNI in the TLS handshake (starttls / tls).
# Leave empty to send none. The server certificate is NOT verified, see README.
my $TLS_SERVER_NAME = "";

# Banner check. A Perl regular expression that must match the server's 220
# banner text (e.g. 'ESMTP Postfix' or '^mail\.example\.com '). Use single
# quotes so backslashes stay untouched; add (?i) at the start for a
# case-insensitive match. Empty = no check.
my $BANNER_MATCH = '';

# Latency limit in milliseconds for the whole probe (connect up to the last
# SMTP step). If the probe succeeds but took longer, the service is reported
# DOWN with "Response too slow". 0 = no limit.
my $MAX_LATENCY_MS = 0;

# Debug log. 1 = append every step (commands sent, replies received, TLS
# details, result, timing) to $DEBUG_FILE. Use it for troubleshooting only and
# switch it off afterwards. The file is created with mode 0600 and is rotated
# to <file>.1 when it exceeds 1 MiB. 0 = no logging.
my $DEBUG      = 0;
my $DEBUG_FILE = "/var/log/NetScaler-SMTP-Monitor.log";

################################################################################
## End of configuration
################################################################################

use constant MAX_BUFFER    => 65536;      # upper limit for unparsed server data (bytes)
use constant MAX_LOG_BYTES => 1048576;    # debug log rotation size (bytes)

my $rbuf      = "";    # receive buffer, filled by sysread only
my $deadline  = 0;     # absolute time at which the whole probe must be finished
my $banner_re;         # compiled $BANNER_MATCH (set by config_error)
my $log_tag   = "";    # "[ip:port]" prefix for debug log lines

sub now
{
	return $have_hires ? Time::HiRes::time() : time();
}

# Seconds left until the probe deadline (0 if already passed).
sub remaining
{
	my $left = $deadline - now();
	return $left > 0 ? $left : 0;
}

# Appends one line to the debug log (only if $DEBUG is on). Never dies and
# never influences the probe result. Non-printable characters are replaced so
# server replies cannot inject fake log lines.
sub dbg
{
	return unless $DEBUG;
	my ($msg) = @_;
	eval {
		$msg =~ s/[^\x20-\x7e]/?/g;
		$msg = substr($msg, 0, 300) . "..." if length($msg) > 300;
		my $t     = now();
		my @lt    = localtime(int($t));
		my $stamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d.%03d",
			$lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0],
			($t - int($t)) * 1000);
		if (-e $DEBUG_FILE && (-s $DEBUG_FILE) > MAX_LOG_BYTES) {
			rename($DEBUG_FILE, "$DEBUG_FILE.1");
		}
		my $old_umask = umask(077);
		my $opened    = open(my $fh, '>>', $DEBUG_FILE);
		umask($old_umask);
		if ($opened) {
			flock($fh, LOCK_EX);
			print $fh "$stamp [$$] $log_tag $msg\n";
			close($fh);
		}
	};
}

sub is_ipv4_address
{
	return $_[0] =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ ? 1 : 0;
}

# Returns an error text if the configuration is unusable, otherwise undef.
# Also compiles $BANNER_MATCH into $banner_re.
sub config_error
{
	return "Invalid TLS_MODE '$TLS_MODE' (use plain, starttls or tls)"
		unless $TLS_MODE =~ /^(?:plain|starttls|tls)$/;
	return "Invalid PROXY_PROTOCOL (use 0, 1 or 2)" unless $PROXY_PROTOCOL =~ /^[012]$/;
	return "PROXY_PROTOCOL 2 needs Socket::inet_pton (newer Perl)"
		if $PROXY_PROTOCOL == 2 && !Socket->can('inet_pton');
	return "Invalid MAIL_TEST (use 0 or 1)"        unless $MAIL_TEST        =~ /^[01]$/;
	return "Invalid ACCEPT_TEMP_FAIL (use 0 or 1)" unless $ACCEPT_TEMP_FAIL =~ /^[01]$/;
	return "Invalid DEBUG (use 0 or 1)"            unless $DEBUG            =~ /^[01]$/;
	return "Invalid MAX_LATENCY_MS (use a number of milliseconds, 0 = off)"
		unless $MAX_LATENCY_MS =~ /^\d+$/;
	if ($MAIL_TEST) {
		return "MAIL_TEST needs MAIL_FROM and RCPT_TO" if $MAIL_FROM eq '' || $RCPT_TO eq '';
		# keep control characters and brackets out of the SMTP commands
		return "Invalid MAIL_FROM" if $MAIL_FROM =~ /[\s<>\x00-\x1f\x7f]/;
		return "Invalid RCPT_TO"   if $RCPT_TO   =~ /[\s<>\x00-\x1f\x7f]/;
	}
	return "Invalid EHLO_DOMAIN"     if $EHLO_DOMAIN     =~ /[\s\x00-\x1f\x7f]/;
	return "Invalid TLS_SERVER_NAME" if $TLS_SERVER_NAME !~ /^[A-Za-z0-9.-]*$/;
	return "Invalid DEBUG_FILE" if $DEBUG && ($DEBUG_FILE eq '' || $DEBUG_FILE =~ /[\x00-\x1f\x7f]/);

	$banner_re = undef;
	if ($BANNER_MATCH ne '') {
		$banner_re = eval { qr/$BANNER_MATCH/ };
		return "Invalid BANNER_MATCH regular expression" unless defined $banner_re;
	}
	return undef;
}

# Strips an IPv6 zone id ("fe80::1%eth0" -> "fe80::1").
sub strip_zone
{
	my ($addr) = @_;
	$addr =~ s/%.*$//;
	return $addr;
}

# PROXY protocol version 1: one text line.
sub proxy_header_v1
{
	my ($sock, $is_v4) = @_;
	return sprintf("PROXY %s %s %s %d %d\r\n",
		$is_v4 ? "TCP4" : "TCP6",
		$sock->sockhost, $sock->peerhost,
		$sock->sockport, $sock->peerport);
}

# PROXY protocol version 2: binary header (12 byte signature, version/command
# 0x21 = v2 PROXY, family/protocol 0x11 = TCP over IPv4 or 0x21 = TCP over IPv6,
# length, then source address, destination address, source port, destination
# port in network byte order). Returns undef if the addresses cannot be packed.
sub proxy_header_v2
{
	my ($sock, $is_v4) = @_;
	my ($af, $fam, $len) = $is_v4
		? (Socket::AF_INET(),  0x11, 12)
		: (Socket::AF_INET6(), 0x21, 36);
	my $src = Socket::inet_pton($af, strip_zone($sock->sockhost));
	my $dst = Socket::inet_pton($af, strip_zone($sock->peerhost));
	return undef unless defined $src && defined $dst;
	return "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"
		. pack("CCn", 0x21, $fam, $len)
		. $src . $dst
		. pack("nn", $sock->sockport, $sock->peerport);
}

# Reads one (possibly multi-line) SMTP reply with sysread into $rbuf.
# Returns (code, text of all reply lines) or () on timeout, EOF or garbage.
# <$sock> is deliberately not used: Perl's own buffering hides already received
# lines from select(), which stalls on multi-line replies such as EHLO.
sub smtp_reply
{
	my ($sock, $sel) = @_;
	my ($code, $all) = (undef, "");
	while (1) {
		# handle all complete lines that are already buffered
		while ($rbuf =~ s/^([^\n]*)\n//) {
			my $line = $1;
			$line =~ s/\r$//;
			dbg("S: $line");
			if ($line =~ /^(\d{3})([ -])(.*)$/) {
				$code = $1;
				my $sep = $2;
				$all .= "$3\n";
				return ($code, $all) if $sep eq ' ';
			}
			else {
				return ();
			}
		}
		return () if length($rbuf) > MAX_BUFFER;

		# fetch more data (a TLS socket may hold decrypted data internally)
		my $pending = $sock->can('pending') && $sock->pending;
		unless ($pending) {
			my $left = remaining();
			return () if $left <= 0 || !$sel->can_read($left);
		}
		my $chunk;
		my $n = $sock->sysread($chunk, 4096);
		return () unless $n;
		$rbuf .= $chunk;
	}
}

# Sends one command and checks that the reply code matches /^$expect/.
# Returns (error text or undef, reply text, reply code).
sub smtp_cmd
{
	my ($sock, $sel, $cmd, $expect) = @_;
	dbg("C: $cmd");
	print $sock "$cmd\r\n" or return ("Unable to send '$cmd' - $!", "", undef);
	my ($code, $text) = smtp_reply($sock, $sel);
	return ("No valid reply to '$cmd' (timeout or connection closed)", "", undef) unless defined $code;
	(my $shown = $text) =~ s/\s+$//;
	$shown =~ s/\n/ /g;
	return ("'$cmd' rejected: $code $shown", $text, $code) unless $code =~ /^$expect/;
	return (undef, $text, $code);
}

# Upgrades a connected socket to TLS. Returns an error text or undef.
# Certificates are not verified: the monitor connects by IP address and only
# checks that the service answers; no credentials or mail content are sent.
sub upgrade_tls
{
	my ($sock) = @_;
	return "IO::Socket::SSL is not available" unless $have_ssl;
	my $left = remaining();
	return "Timeout before TLS handshake" if $left <= 0;
	my %opt = (
		SSL_verify_mode => 0x00,    # SSL_VERIFY_NONE
		Timeout         => $left,
	);
	$opt{SSL_hostname} = $TLS_SERVER_NAME if $TLS_SERVER_NAME ne '';
	unless (IO::Socket::SSL->start_SSL($sock, %opt)) {
		return "TLS handshake failed - " . (IO::Socket::SSL::errstr() || "unknown");
	}
	$rbuf = "";    # data received before the upgrade is no longer valid
	if ($DEBUG) {
		my $ver    = eval { $sock->can('get_sslversion') ? $sock->get_sslversion() : undef } || "?";
		my $cipher = eval { $sock->can('get_cipher')     ? $sock->get_cipher()     : undef } || "?";
		dbg("TLS established: $ver, $cipher");
	}
	return undef;
}

# Closes the socket and returns the failure result.
sub fail
{
	my ($sock, $msg) = @_;
	close($sock) if $sock;
	return (1, $msg);
}

# The actual probe. Returns 0 on success, (1, "reason") on failure.
sub run_probe
{
	# $_[0] = IP address, $_[1] = port, $_[3] = timeout
	return (1, "Invalid number of arguments") if scalar(@_) < 2;
	my $cfg_error = config_error();
	return (1, $cfg_error) if defined $cfg_error;

	local $SIG{PIPE} = 'IGNORE';    # a closed peer must not kill the probe

	my ($ip, $port) = ($_[0], $_[1]);
	my $timeout = $_[3] || 5;
	$timeout = $timeout / 1000 if $timeout > 100;    # defensive: treat large values as milliseconds
	$deadline = now() + $timeout;
	$rbuf     = "";

	# --- Connect --------------------------------------------------------------
	my $is_v4 = is_ipv4_address($ip);
	my $sock;
	if ($is_v4) {
		$sock = IO::Socket::INET->new(
			PeerAddr => $ip, PeerPort => $port,
			Proto    => 'tcp', Timeout  => $timeout)
			or return (1, "Unable to connect to server - $!");
	}
	else {
		return (1, "IPv6 target but IO::Socket::INET6 is not available") unless $have_inet6;
		$sock = IO::Socket::INET6->new(
			PeerAddr => $ip, PeerPort => $port,
			Proto    => 'tcp', Timeout  => $timeout)
			or return (1, "Unable to connect to server - $!");
	}
	$sock->autoflush(1);
	dbg(sprintf("Connected %s:%d -> %s:%d", $sock->sockhost, $sock->sockport, $sock->peerhost, $sock->peerport));

	# --- PROXY protocol (always clear text, always the first bytes) ------------
	if ($PROXY_PROTOCOL) {
		my $hdr = $PROXY_PROTOCOL == 2 ? proxy_header_v2($sock, $is_v4) : proxy_header_v1($sock, $is_v4);
		return fail($sock, "Unable to build PROXY protocol v$PROXY_PROTOCOL header") unless defined $hdr;
		dbg("PROXY protocol v$PROXY_PROTOCOL header sent (" . length($hdr) . " bytes)");
		print $sock $hdr or return fail($sock, "Unable to send PROXY header - $!");
	}

	# --- Implicit TLS: handshake before the banner -----------------------------
	if ($TLS_MODE eq 'tls') {
		my $err = upgrade_tls($sock);
		return fail($sock, $err) if $err;
	}

	# --- Banner ----------------------------------------------------------------
	my $sel = IO::Select->new($sock);
	my ($code, $text) = smtp_reply($sock, $sel);
	return fail($sock, "No valid SMTP banner (timeout or connection closed)") unless defined $code;
	return fail($sock, "Unexpected SMTP banner: $code") unless $code eq '220';
	if (defined $banner_re && $text !~ $banner_re) {
		(my $shown = $text) =~ s/\s+/ /g;
		$shown =~ s/[^\x20-\x7e]/?/g;
		return fail($sock, "Banner does not match BANNER_MATCH: '" . substr($shown, 0, 80) . "'");
	}

	# --- EHLO / STARTTLS / mail transaction ------------------------------------
	if ($TLS_MODE eq 'starttls' || $MAIL_TEST) {
		my $helo = $EHLO_DOMAIN;
		if ($helo eq '') {
			my $local = $sock->sockhost;
			$helo = $is_v4 ? "[$local]" : "[IPv6:$local]";
		}

		my ($err, $resp, $rc) = smtp_cmd($sock, $sel, "EHLO $helo", "250");
		return fail($sock, $err) if $err;

		if ($TLS_MODE eq 'starttls') {
			return fail($sock, "STARTTLS not offered by server") unless $resp =~ /^STARTTLS\s*$/mi;
			($err, $resp, $rc) = smtp_cmd($sock, $sel, "STARTTLS", "220");
			return fail($sock, $err) if $err;

			$err = upgrade_tls($sock);
			return fail($sock, $err) if $err;

			# a new EHLO is required after the upgrade and proves the TLS session works
			($err, $resp, $rc) = smtp_cmd($sock, $sel, "EHLO $helo", "250");
			return fail($sock, $err) if $err;
		}

		if ($MAIL_TEST) {
			my $mail_ok = $ACCEPT_TEMP_FAIL ? '(?:250|4\d\d)' : '250';
			my $rcpt_ok = $ACCEPT_TEMP_FAIL ? '(?:25|4\d\d)'  : '25';

			($err, $resp, $rc) = smtp_cmd($sock, $sel, "MAIL FROM:<$MAIL_FROM>", $mail_ok);
			return fail($sock, $err) if $err;
			if ($rc =~ /^4/) {
				dbg("Temporary failure on MAIL FROM accepted (ACCEPT_TEMP_FAIL)");
			}
			else {
				($err, $resp, $rc) = smtp_cmd($sock, $sel, "RCPT TO:<$RCPT_TO>", $rcpt_ok);
				return fail($sock, $err) if $err;
				dbg("Temporary failure on RCPT TO accepted (ACCEPT_TEMP_FAIL)") if $rc =~ /^4/;
			}

			# abort the transaction; DATA is never sent
			dbg("C: RSET");
			print $sock "RSET\r\n";
			smtp_reply($sock, $sel);
		}
	}

	dbg("C: QUIT");
	print $sock "QUIT\r\n";
	close($sock);
	return 0;
}

# KAS probe handler: runs the probe, applies the latency limit and writes the
# debug log. Returns 0 on success, (1, "reason") on failure.
sub smtp_probe
{
	my $t0 = now();
	$log_tag = "[" . (defined $_[0] ? $_[0] : "?") . ":" . (defined $_[1] ? $_[1] : "?") . "]";
	dbg("Probe start: tls=$TLS_MODE proxy=$PROXY_PROTOCOL mail_test=$MAIL_TEST "
		. "temp_fail_ok=$ACCEPT_TEMP_FAIL max_latency_ms=$MAX_LATENCY_MS");

	my @r  = run_probe(@_);
	my $ms = (now() - $t0) * 1000;

	if ($r[0] == 0 && $MAX_LATENCY_MS =~ /^\d+$/ && $MAX_LATENCY_MS > 0 && $ms > $MAX_LATENCY_MS) {
		@r = (1, sprintf("Response too slow: %d ms (limit %d ms)", $ms, $MAX_LATENCY_MS));
	}

	dbg(sprintf("RESULT: %s (%d ms)", $r[0] == 0 ? "OK" : "FAILED - $r[1]", $ms));
	return 0 if $r[0] == 0;
	return (1, $r[1]);
}

# Register the probe handler with the KAS module.
probe(\&smtp_probe);
