# Changelog

All notable changes to NetScaler-SMTP-Monitor are documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions
follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-14

First public release.

### Features

- SMTP user monitor for NetScaler (KAS) in a single Perl script,
  `NetScaler-SMTP-Monitor.pl`.
- `$TLS_MODE`: `plain`, `starttls` (port 25/587) and `tls` (implicit TLS, port 465).
- `$PROXY_PROTOCOL`: `0` off, `1` PROXY protocol v1 (text), `2` PROXY protocol v2
  (binary). Sent first and unencrypted, also before the TLS handshake in `tls`
  mode. IPv4 and IPv6.
- `$MAIL_TEST`: optional SMTP transaction test (`EHLO`, `MAIL FROM`, `RCPT TO`,
  `RSET`, `QUIT`). `DATA` is never sent, so no mail is delivered.
- `$ACCEPT_TEMP_FAIL`: optionally treat `4xx` answers to `MAIL FROM` / `RCPT TO`
  (greylisting, postscreen) as "server is alive".
- `$BANNER_MATCH`: optional regular expression the `220` banner must match.
- `$MAX_LATENCY_MS`: optional latency limit; a successful but slow probe is
  reported DOWN with "Response too slow".
- `$DEBUG` / `$DEBUG_FILE`: optional step-by-step debug log (mode `0600`,
  rotated at 1 MiB, sanitized).
- `$EHLO_DOMAIN`: configurable EHLO name; defaults to the monitor's own IP as
  address literal, so no domain is required.
- `$TLS_SERVER_NAME`: optional SNI name for the TLS handshake.
- IPv4 and IPv6 backends.
- Clear failure messages that name the step that failed.
- Quick-Start Guide (`QUICKSTART.md`) and full documentation (`README.md`).

### Robustness and security

- Replies are read with `sysread` into an own buffer. Reading with `<$sock>`
  together with `select()` stalls on multi-line replies such as the EHLO answer.
- One deadline for the whole probe, derived from the timeout NetScaler passes in.
- Receive buffer is bounded; endless server output ends the probe.
- Configured addresses and names are validated before use in SMTP commands.
- `$BANNER_MATCH` cannot execute code; invalid expressions are reported.
- `SIGPIPE` is ignored so a closed connection cannot kill the monitor process.
- Server certificates are not verified (see the README, "Security notes").

### Installation notes

- The script is stored in `/flash/netscaler/monitors` (SCP or web GUI upload) and
  needs execute permission (`chmod +x`).
- The `@` in e-mail addresses must be escaped with a backslash
  (`"monitor\@example.com"`).

### Notes

- Defaults (`plain`, no PROXY header, no mail test, no banner check, no latency
  limit, no debug log) give a light check: connect, wait for the `220` banner,
  `QUIT`.
- Verified on NetScaler 13.1, 14.1 and 15.1: IPv4, IPv6, all TLS modes, PROXY
  protocol, mail test and timeouts.
