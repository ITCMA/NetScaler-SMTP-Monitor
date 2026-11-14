# Quick-Start Guide

Get NetScaler-SMTP-Monitor running in about ten minutes. For every option in
detail see the [README](README.md).

## What you need

- Shell access to the NetScaler (SSH as `nsroot`) and the file
  `NetScaler-SMTP-Monitor.pl` from this repository.
- An SMTP service (or service group) already configured on the NetScaler.
- For TLS: the Perl module `IO::Socket::SSL`. Check it on the NetScaler shell
  (type `shell` first if you are in the NetScaler CLI):

  ```bash
  perl -MIO::Socket::SSL -e 'print "ok\n"'
  ```

  `ok` means it is available. Plain mode needs no extra module. More checks
  (IPv6, PROXY v2, timer) are listed in the README under *Requirements*.

## Step 1: Choose your settings

Find your situation. The settings go into the configuration block at the top of
the script in step 3.

| Your SMTP service | Settings |
|---|---|
| Port 25, just check that it is alive | none (defaults) |
| Port 25, backend needs the PROXY protocol | `$PROXY_PROTOCOL = 1;` (or `2;`) |
| Port 587 with STARTTLS | `$TLS_MODE = "starttls";` |
| Port 465 (SMTPS, TLS from the first byte) | `$TLS_MODE = "tls";` |
| Check that sender and recipient are accepted | `$MAIL_TEST = 1;` plus `$MAIL_FROM` and `$RCPT_TO` |
| Greylisting or postscreen answers `450` | add `$ACCEPT_TEMP_FAIL = 1;` |

Which PROXY version? Use the one your backend is configured for. When in doubt,
take `1`. A backend without PROXY support rejects the monitor, so enable it only
if the real clients' connections through the NetScaler also use it.

## Step 2: Copy the script to the NetScaler

The script belongs into `/flash/netscaler/monitors`:

```bash
scp NetScaler-SMTP-Monitor.pl nsroot@<nsip>:/flash/netscaler/monitors/
```

Instead of SCP you can upload the file through the NetScaler management GUI into
the same directory. In an HA pair or cluster, make sure the file is present on
every node.

## Step 3: Edit the settings

Open the script (locally before the upload, or on the NetScaler with `vi`) and
change the lines in the configuration block, for example for port 587 with
STARTTLS:

```perl
my $TLS_MODE = "starttls";
```

Rules for the values:

- One setting per line, in the form `my $NAME = value;`. Keep the semicolon.
- Text is in quotes: `"starttls"`. Numbers `0` and `1` are not.
- **Escape the `@` in e-mail addresses with a backslash**, otherwise the script
  does not work at all:

  ```perl
  my $MAIL_FROM = "monitor\@example.com";     # correct
  my $RCPT_TO   = "postmaster\@example.com";  # correct
  ```

## Step 4: Make the script executable

On the NetScaler shell:

```bash
chmod +x /flash/netscaler/monitors/NetScaler-SMTP-Monitor.pl
ls -l /flash/netscaler/monitors/NetScaler-SMTP-Monitor.pl
```

The permissions in the `ls` output must contain an `x`. Without it the monitor
does not work.

## Step 5: Create the monitor and bind it

In the NetScaler CLI:

```
add lb monitor NetScaler-SMTP-Monitor USER -scriptName NetScaler-SMTP-Monitor.pl -dispatcherIP 127.0.0.1 -dispatcherPort 3013
bind service <service-name> -monitorName NetScaler-SMTP-Monitor
```

For a service group: `bind serviceGroup <name> -monitorName NetScaler-SMTP-Monitor`.

## Step 6: Check the result

```
show service <service-name>
```

The service should be UP. If it is DOWN, the last response names the failed
step, for example `'RCPT TO:<...>' rejected: 550 ...`. The README has a table of
all responses with their causes.

If you change the script later and still see the old behavior, unbind and bind
the monitor again, then check once more.

## If something does not work

Go through this list first:

1. The script is in `/flash/netscaler/monitors`, and `ls -l` shows `x`.
2. `-scriptName` matches the file name exactly (upper and lower case).
3. E-mail addresses have `\@`, not `@`.
4. For `$PROXY_PROTOCOL`: the backend really expects the header on this port,
   in this version.
5. `$TLS_MODE` fits the port: `tls` for 465, `starttls` for 25 and 587, `plain`
   without encryption.

Still stuck? Switch on the debug log in the script:

```perl
my $DEBUG = 1;
```

Then watch it on the NetScaler shell while the monitor probes:

```bash
tail -f /var/log/NetScaler-SMTP-Monitor.log
```

Every step appears with what the monitor sent (`C:`) and what the server
answered (`S:`). **Set `$DEBUG` back to `0` when you are done**, because the
monitor probes often and the log grows.

## More recipes

Settings for typical cases. Copy the lines into the configuration block.

**Backend with PROXY protocol, port 25:**

```perl
my $PROXY_PROTOCOL = 1;
```

**Port 465 with PROXY protocol and recipient check:**

```perl
my $TLS_MODE       = "tls";
my $PROXY_PROTOCOL = 1;
my $MAIL_TEST      = 1;
my $MAIL_FROM      = "monitor\@example.com";
my $RCPT_TO        = "postmaster\@example.com";
```

**Greylisting or postscreen in front of Postfix:**

```perl
my $MAIL_TEST        = 1;
my $MAIL_FROM        = "monitor\@example.com";
my $RCPT_TO          = "postmaster\@example.com";
my $ACCEPT_TEMP_FAIL = 1;
```

**Make sure the right server answers, and that it answers fast:**

```perl
my $BANNER_MATCH   = '^mail\.example\.com ESMTP';
my $MAX_LATENCY_MS = 1500;
```

Use single quotes for `$BANNER_MATCH`, so backslashes stay as they are.

## Several variants

Settings live inside the script. For two different setups (for example port 25
and port 465), copy the script under a second name, for example
`NetScaler-SMTP-Monitor-465.pl`, change its settings, run `chmod +x` on it, and
create a second monitor with `-scriptName NetScaler-SMTP-Monitor-465.pl`.
