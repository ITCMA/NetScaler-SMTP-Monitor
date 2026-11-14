# NetScaler-SMTP-Monitor

A user monitor (Perl, KAS) for NetScaler that checks whether an SMTP server is
alive, with options the stock SMTP monitor does not offer:

- **PROXY protocol v1 and v2**: send the PROXY header for backends that require
  it (for example Postfix behind a NetScaler load balancer).
- **TLS**: plain, **STARTTLS** (port 25/587) or **implicit TLS** (port 465).
- **Mail transaction test**: `EHLO`, `MAIL FROM`, `RCPT TO`, so you can verify
  that the server accepts a sender and a recipient. `DATA` is never sent: **no
  mail is delivered or queued.**
- **Temporary failures accepted**: optionally treat `4xx` answers (greylisting,
  postscreen) as "server is alive".
- **Banner check**: optionally require the banner to match a regular expression.
- **Latency limit**: optionally mark the service DOWN when the answer is too slow.
- **Debug log**: optionally write every step to a log file for troubleshooting.

All options are independent and switched in a short configuration block at the
top of the script. With the defaults the monitor connects, waits for the `220`
banner and quits.

**New here? Start with the [Quick-Start Guide](QUICKSTART.md).**

> NetScaler and Citrix are trademarks of Cloud Software Group, Inc. or its
> subsidiaries. This project is independent and not affiliated with or endorsed
> by them.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Option details](#option-details)
- [Examples](#examples)
- [Monitor responses and troubleshooting](#monitor-responses-and-troubleshooting)
- [Debug log](#debug-log)
- [Security notes](#security-notes)
- [Limitations](#limitations)
- [Tested with](#tested-with)
- [License](#license)

## How it works

For every probe the monitor does the following. Steps in brackets are optional
and depend on the configuration.

```
connect (TCP, IPv4 or IPv6)
[PROXY protocol header, v1 or v2]               PROXY_PROTOCOL = 1 or 2
[TLS handshake]                                 TLS_MODE = "tls"
read banner, expect 220
[banner must match regular expression]          BANNER_MATCH
[EHLO]                                          TLS_MODE = "starttls" or MAIL_TEST = 1
[STARTTLS, TLS handshake, EHLO again]           TLS_MODE = "starttls"
[MAIL FROM, RCPT TO, RSET]                      MAIL_TEST = 1
QUIT
[total time must be below the limit]            MAX_LATENCY_MS
```

The service is UP if every step succeeds and DOWN with a short reason
otherwise. The whole probe, including all network waits, is limited by the
timeout the NetScaler hands to the monitor, so a stalled backend cannot hold
the probe open.

The PROXY header is always sent unencrypted and before anything else, also in
`tls` mode. This is how the PROXY protocol works; the server reads the header
first and then starts the TLS handshake.

## Requirements

- NetScaler with user monitor (KAS) support. The script uses the
  `Netscaler::KAS` module that ships with NetScaler.
- Perl modules (all present on the tested releases, see below). Check on the
  NetScaler shell:

  | Needed for | Module | Check |
  |---|---|---|
  | `starttls` and `tls` | `IO::Socket::SSL` | `perl -MIO::Socket::SSL -e 'print "ok\n"'` |
  | IPv6 backends | `IO::Socket::INET6` | `perl -MIO::Socket::INET6 -e 'print "ok\n"'` |
  | PROXY protocol v2 | `Socket` with `inet_pton` | `perl -MSocket=inet_pton -e 'print "ok\n"'` |
  | millisecond latency | `Time::HiRes` | `perl -MTime::HiRes -e 'print "ok\n"'` |

  `IO::Socket::INET` and `IO::Select` are part of Perl itself. Plain mode with
  IPv4 needs nothing else. Without `Time::HiRes` the latency limit only works
  in whole seconds.

## Installation

For a short step-by-step version with copy-and-paste settings see the
[Quick-Start Guide](QUICKSTART.md).

### 1. Put the script on the NetScaler

The script must be stored in **`/flash/netscaler/monitors`**. Two ways to get it
there:

- **SCP** (replace `<nsip>` with the NSIP or management address):

  ```bash
  scp NetScaler-SMTP-Monitor.pl nsroot@<nsip>:/flash/netscaler/monitors/
  ```

- **Web GUI**: upload the file through the NetScaler management GUI, so that it
  ends up in the same directory.

Keep the file name `NetScaler-SMTP-Monitor.pl`, or choose your own. Do not reuse
the name of a stock NetScaler script, because stock scripts in this directory
are replaced on reboot.

In an HA pair or cluster, make sure the file exists on every node.

### 2. Give the script execute permission

The monitor does **not work** unless the script is executable. On the NetScaler
shell:

```bash
chmod +x /flash/netscaler/monitors/NetScaler-SMTP-Monitor.pl
```

Check the result with `ls -l /flash/netscaler/monitors/NetScaler-SMTP-Monitor.pl`;
the permission string must contain `x`.

### 3. Edit the configuration

Open the script and edit the configuration block at the top, see
[Configuration](#configuration). Edit it before or after the upload, but
before you bind the monitor to a service.

### 4. Create the monitor and bind it

```
add lb monitor NetScaler-SMTP-Monitor USER -scriptName NetScaler-SMTP-Monitor.pl -dispatcherIP 127.0.0.1 -dispatcherPort 3013
bind service <service-name> -monitorName NetScaler-SMTP-Monitor
```

For a service group use
`bind serviceGroup <name> -monitorName NetScaler-SMTP-Monitor`.

### 5. Verify

`show service <service-name>` lists the monitor with its state and the last
response. A healthy backend is UP; a failure shows the reason, see
[Monitor responses](#monitor-responses-and-troubleshooting).

### Several variants

Settings are variables inside the script. If you need several variants (for
example one monitor for port 25 with PROXY protocol and one for port 465 with
TLS), keep one copy of the script per variant with different file names and
settings, give each copy execute permission, and create one monitor per copy.

## Configuration

All settings are variables in the block between the two `####` lines at the top
of the script. Every setting is one line `my $NAME = value;`: text values are in
quotes, every line ends with a semicolon.

| Variable | Values | Default | Meaning |
|---|---|---|---|
| `$TLS_MODE` | `plain`, `starttls`, `tls` | `plain` | `plain`: no encryption. `starttls`: upgrade with `STARTTLS` (port 25/587). `tls`: TLS from the first byte, implicit TLS/SMTPS (port 465). |
| `$PROXY_PROTOCOL` | `0`, `1`, `2` | `0` | `0`: off. `1`: PROXY protocol version 1 (text). `2`: version 2 (binary). Enable only if the backend expects it; otherwise it rejects the monitor. |
| `$MAIL_TEST` | `0`, `1` | `0` | `1`: after `EHLO` send `MAIL FROM` and `RCPT TO` and require that both are accepted, then `RSET` and `QUIT`. No `DATA`, no mail. |
| `$MAIL_FROM` | address | empty | Sender for the test. Required if `$MAIL_TEST = 1`. |
| `$RCPT_TO` | address | empty | Recipient for the test. Required if `$MAIL_TEST = 1`. |
| `$ACCEPT_TEMP_FAIL` | `0`, `1` | `0` | `1`: a `4xx` answer to `MAIL FROM` or `RCPT TO` counts as "server is alive". Only relevant with `$MAIL_TEST = 1`. |
| `$EHLO_DOMAIN` | host name | empty | Name announced in `EHLO`. Empty: the monitor's own IP as address literal, for example `[192.0.2.10]`. |
| `$TLS_SERVER_NAME` | host name | empty | Optional SNI name for the TLS handshake (`starttls`, `tls`). Empty: no SNI. |
| `$BANNER_MATCH` | Perl regex in single quotes | empty | The `220` banner text must match. Empty: no check. |
| `$MAX_LATENCY_MS` | number | `0` | DOWN if the probe takes longer than this many milliseconds. `0`: no limit. |
| `$DEBUG` | `0`, `1` | `0` | `1`: write a step-by-step log to `$DEBUG_FILE`. |
| `$DEBUG_FILE` | file path | `/var/log/NetScaler-SMTP-Monitor.log` | Where the debug log is written. |

Invalid settings (unknown `$TLS_MODE`, `$PROXY_PROTOCOL = 3`, `$MAIL_TEST = 1`
without addresses, control characters or brackets in addresses, an invalid
regular expression, and so on) make the monitor fail immediately with a message
that names the problem.

### Escape the @ in e-mail addresses

**The `@` in `$MAIL_FROM` and `$RCPT_TO` must be escaped with a backslash.**
In a Perl double-quoted string, `@` starts an array variable. Without the
backslash Perl cannot compile the script and the monitor does not work.

```perl
my $MAIL_FROM = "monitor\@example.com";     # correct
my $RCPT_TO   = "postmaster\@example.com";  # correct

my $MAIL_FROM = "monitor@example.com";      # WRONG: script does not compile
```

In single quotes no escaping is needed (`'monitor@example.com'`), but use one
style consistently.

## Option details

### PROXY protocol (`$PROXY_PROTOCOL`)

The header tells the backend the connection's source and destination address
and port. For a monitor these are the monitor's own source IP and port (the
SNIP or NSIP the probe leaves from) and the backend's IP and port.

- `1`: version 1, one text line, for example
  `PROXY TCP4 192.0.2.10 192.0.2.20 51234 25`.
- `2`: version 2, the binary format (12-byte signature, command `PROXY`,
  family TCP over IPv4 or IPv6, addresses and ports). No optional extensions
  (TLVs) are sent.

Use the version your backend is configured for. Postfix with
`smtpd_upstream_proxy_protocol = haproxy` (or
`postscreen_upstream_proxy_protocol = haproxy`) accepts both. A server that
expects no PROXY header treats it as garbage and drops the connection.

### Temporary failures (`$ACCEPT_TEMP_FAIL`)

Greylisting and postscreen typically answer the first contact of an unknown
client with a temporary `4xx` code, for example `450`, to `RCPT TO`. That is
not a failure of the server, but a strict monitor would mark it DOWN.

With `$ACCEPT_TEMP_FAIL = 1`:

- A `4xx` answer to `MAIL FROM` or `RCPT TO` counts as success. If `MAIL FROM`
  is deferred, `RCPT TO` is not sent.
- `5xx` answers, timeouts and every other error still count as failure.
- The transaction is then not verified end to end: the monitor only knows the
  server is alive and answers correctly. Decide whether that is enough, or
  add the monitoring IP to the server's allow list and keep the strict
  default.

### Banner check (`$BANNER_MATCH`)

A Perl regular expression matched against the text of the `220` banner (all
banner lines, without the status code). Use single quotes so backslashes stay
untouched.

| Setting | Matches banner such as |
|---|---|
| `'ESMTP Postfix'` | `mail.example.com ESMTP Postfix` |
| `'^mail\.example\.com '` | `mail.example.com ESMTP ...` (starts with this host name) |
| `'(?i)postfix'` | `POSTFIX`, `Postfix`, `postfix` (case-insensitive) |

Use it to make sure the right service answers on the port, for example behind a
shared IP. Code blocks inside the expression are not executed, and an invalid
expression is reported as `Invalid BANNER_MATCH regular expression`. If the
banner does not match, the response contains the first 80 characters of the
banner.

### Latency limit (`$MAX_LATENCY_MS`)

Measures the time from the start of the probe to the end of the last SMTP step,
including the TLS handshake and the mail test. If the probe succeeded but took
longer than the limit, the monitor reports `Response too slow: 812 ms (limit
500 ms)` and the service is DOWN.

The limit works on top of the overall probe timeout the NetScaler passes to the
monitor. A server that does not answer at all is stopped by that timeout; the
latency limit is for servers that answer, but too slowly. Pick a limit below the
monitor's response timeout.

## Examples

**Banner check only** (defaults):

```perl
my $TLS_MODE       = "plain";
my $PROXY_PROTOCOL = 0;
my $MAIL_TEST      = 0;
```

**Backend that requires the PROXY protocol** (version 1 or 2, as configured on
the backend):

```perl
my $TLS_MODE       = "plain";
my $PROXY_PROTOCOL = 2;
```

**Submission port 587 with STARTTLS:**

```perl
my $TLS_MODE = "starttls";
```

**SMTPS on port 465, PROXY protocol, sender and recipient check:**

```perl
my $TLS_MODE       = "tls";
my $PROXY_PROTOCOL = 1;
my $MAIL_TEST      = 1;
my $MAIL_FROM      = "monitor\@example.com";
my $RCPT_TO        = "postmaster\@example.com";
my $EHLO_DOMAIN    = "monitor.example.com";
```

**Greylisting or postscreen in front, tolerate `4xx`:**

```perl
my $MAIL_TEST        = 1;
my $MAIL_FROM        = "monitor\@example.com";
my $RCPT_TO          = "postmaster\@example.com";
my $ACCEPT_TEMP_FAIL = 1;
```

**Check the identity of the server and its speed:**

```perl
my $BANNER_MATCH   = '^mail\.example\.com ESMTP';
my $MAX_LATENCY_MS = 1500;
```

## Monitor responses and troubleshooting

The reason is shown as the monitor's last response, for example in the output
of `show service <service-name>`.

| Response | Likely cause |
|---|---|
| `Unable to connect to server - ...` | Wrong IP/port, firewall, server down. |
| `No valid SMTP banner (timeout or connection closed)` | Server did not send a banner: wrong `$TLS_MODE` (for example `plain` against port 465), missing or wrong PROXY header, or the server closed the connection. |
| `Unexpected SMTP banner: 554` | Server answered with a code other than 220. |
| `Banner does not match BANNER_MATCH: '...'` | The banner text does not match the configured expression. |
| `Unable to send PROXY header` | Server closed the connection immediately. |
| `'EHLO ...' rejected: ...` | Server refused the EHLO name; set `$EHLO_DOMAIN` to a valid host name. |
| `STARTTLS not offered by server` | Server does not advertise STARTTLS on this port. |
| `TLS handshake failed - ...` | Wrong `$TLS_MODE` for the port, or TLS protocol/cipher mismatch. |
| `'MAIL FROM:<...>' rejected: ...` | Server refuses the sender, for example unknown sender domain. |
| `'RCPT TO:<...>' rejected: ...` | Server refuses the recipient, for example relay restrictions or unknown user. With a `4xx` code see `$ACCEPT_TEMP_FAIL`. |
| `Response too slow: N ms (limit M ms)` | The probe succeeded but exceeded `$MAX_LATENCY_MS`. |
| `IO::Socket::SSL is not available` | Perl module missing, see [Requirements](#requirements). |
| `MAIL_TEST needs MAIL_FROM and RCPT_TO`, `Invalid ...` | Configuration error in the script. |

If the monitor is DOWN with no useful response from the start, check:

- the script is in `/flash/netscaler/monitors` and has execute permission
  (`chmod +x`),
- the `-scriptName` of the monitor matches the file name exactly (the file name
  is case-sensitive),
- an e-mail address contains `@` without a backslash, so the script does not
  compile.

If the monitor fails right after you enable `$PROXY_PROTOCOL`, check that the
backend listener really expects the PROXY header on that port, and in the
version you chose (1 or 2). A plain SMTP server treats the header as garbage and
drops the connection.

A mail transaction test shows up in the mail server log on every probe. Use a
dedicated recipient, and keep in mind greylisting, rate limits or postscreen
tests on the backend (see `$ACCEPT_TEMP_FAIL`). Add the NetScaler monitoring IP
(SNIP) to the allow lists where needed.

When the response is not enough, switch on the [debug log](#debug-log).

## Debug log

With `$DEBUG = 1` every probe appends its steps to `$DEBUG_FILE` (default
`/var/log/NetScaler-SMTP-Monitor.log`):

```
2026-11-14 10:15:02.118 [4711] [192.0.2.20:25] Probe start: tls=starttls proxy=2 mail_test=1 temp_fail_ok=0 max_latency_ms=0
2026-11-14 10:15:02.119 [4711] [192.0.2.20:25] Connected 192.0.2.10:51234 -> 192.0.2.20:25
2026-11-14 10:15:02.119 [4711] [192.0.2.20:25] PROXY protocol v2 header sent (28 bytes)
2026-11-14 10:15:02.131 [4711] [192.0.2.20:25] S: 220 mail.example.com ESMTP Postfix
2026-11-14 10:15:02.131 [4711] [192.0.2.20:25] C: EHLO [192.0.2.10]
2026-11-14 10:15:02.133 [4711] [192.0.2.20:25] S: 250-mail.example.com
2026-11-14 10:15:02.133 [4711] [192.0.2.20:25] S: 250 STARTTLS
...
2026-11-14 10:15:02.190 [4711] [192.0.2.20:25] RESULT: OK (72 ms)
```

Each line has time, process id, the probed address and port, and the message
(`C:` is what the monitor sent, `S:` what the server answered).

- Use it for troubleshooting only and switch it off again. A monitor probes
  often, so the log grows quickly. It is rotated to `<file>.1` when it exceeds
  1 MiB, so it takes at most about 2 MiB.
- The file is created readable for its owner only (mode `0600`).
- Server replies are logged with non-printable characters replaced, and long
  lines are cut at 300 characters.
- The monitor sends no credentials and no mail content, so the log contains
  none. It does contain the configured sender and recipient addresses.
- If the log file cannot be written (wrong path, no permission), the probe
  still runs normally; you simply get no log.
- View it on the NetScaler shell, for example with
  `tail -f /var/log/NetScaler-SMTP-Monitor.log`.

## Security notes

- **No certificate verification.** In `starttls` and `tls` mode the server
  certificate is not validated, because the monitor connects by IP address and
  only checks that the service answers. The monitor sends no credentials and no
  mail content, so a man in the middle gains nothing from the monitor
  connection; it does not prove the identity of the backend either. Use
  `$BANNER_MATCH` if you want at least a basic identity check.
- **No mail is delivered.** The transaction is aborted with `RSET` before
  `DATA`. There is no authentication (`AUTH`) in this script.
- **PROXY header content.** It contains the monitor's own source IP and port and
  the backend's IP and port, nothing else.
- **Input handling.** Configured addresses and names are checked for control
  characters, spaces and brackets before they are placed into SMTP commands.
  Server replies are read into a bounded buffer; a server that sends endless
  data cannot exhaust memory. A regular expression in `$BANNER_MATCH` cannot run
  code; it is configured by the administrator and matched against at most 64 KB
  of server data.
- **Resource limits.** One deadline covers the whole probe, and a closed
  connection cannot terminate the monitor process (`SIGPIPE` is ignored).
- **Debug log.** Off by default. When on, the file is private to its owner
  (`0600`), size-limited and sanitized, see [Debug log](#debug-log).
- **File permissions.** Treat the script like any other file in
  `/flash/netscaler/monitors`; it runs on the appliance as part of the
  monitoring service. It needs execute permission, but no write access for
  anyone except administrators.

## Limitations

- Settings are variables in the script, not monitor arguments. Use one script
  copy per variant.
- PROXY protocol version 2 is sent without extensions (TLVs), and always as
  command `PROXY` with the real addresses.
- No `AUTH` and no certificate verification.
- `$ACCEPT_TEMP_FAIL` accepts temporary failures only for `MAIL FROM` and
  `RCPT TO`, not for the banner or `EHLO`.

## Tested with

NetScaler 13.1, 14.1 and 15.1 (latest builds available in November 2026):
IPv4 and IPv6 backends, all three TLS modes, with and without PROXY protocol,
with and without the mail transaction test, and timeout behavior, against
Postfix.

## License

MIT, see [LICENSE](LICENSE).
