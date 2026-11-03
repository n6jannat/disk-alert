# disk-alert

A small Bash script that checks disk usage and alerts you by **email** or **Slack/Discord/Teams webhook**
when a filesystem crosses a warning or critical threshold. It has no dependencies beyond `df`, `awk`,
and optionally `curl` and `mail`.

```
$ ./disk-alert.sh
OK        23%  /                    used 8.7G of 252G (30G free, ext4)
WARNING   84%  /var                 used 42G of 50G (8.0G free, ext4)
CRITICAL  95%  /data                used 950G of 1.0T (50G free, xfs)
```

## Quick start

```bash
git clone https://github.com/<your-user>/disk-alert.git
cd disk-alert
./disk-alert.sh                 # check all disks with defaults (warn 80%, crit 90%)
./disk-alert.sh -w 70 -c 85     # custom thresholds
./disk-alert.sh -m / -m /home   # only check specific mount points
./disk-alert.sh -w 0 -n         # dry run: forces a warning and shows the alert it would send
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-w, --warn PERCENT` | Warning threshold | `80` |
| `-c, --crit PERCENT` | Critical threshold | `90` |
| `-m, --mount PATH` | Only check this mount point (repeatable) | all |
| `-e, --email ADDRESS` | Email alerts to this address (needs `mail` or `sendmail`) | off |
| `-u, --webhook URL` | Post alerts to a Slack/Discord/Teams webhook (needs `curl`) | off |
| `-l, --log FILE` | Append every result to a log file | off |
| `-f, --config FILE` | Load settings from a config file | – |
| `-n, --dry-run` | Print the alert instead of sending it | – |
| `-q, --quiet` | Only print filesystems over a threshold | – |

Each setting can also be set with an environment variable of the same name, for example
`WARN_THRESHOLD=75 ./disk-alert.sh`.

### Exit codes
`0` all OK · `1` warning · `2` critical · `3` error. This makes the script work with Nagios-style
monitoring and with CI checks.

## Install and schedule with cron

```bash
sudo cp disk-alert.sh /usr/local/bin/disk-alert
sudo cp disk-alert.conf.example /etc/disk-alert.conf
sudo nano /etc/disk-alert.conf      # set your email / webhook
disk-alert -f /etc/disk-alert.conf -n   # test it first
```

Run it every 15 minutes:
```bash
sudo crontab -e
```
```cron
*/15 * * * * /usr/local/bin/disk-alert -f /etc/disk-alert.conf -q
```

## Slack alerts
1. Create an incoming webhook: https://api.slack.com/messaging/webhooks
2. `./disk-alert.sh -u "https://hooks.slack.com/services/XXX/YYY/ZZZ"`

Discord and Microsoft Teams webhooks also work.

## Tests

```bash
./tests/test.sh
```
GitHub Actions runs ShellCheck and the tests on every push (`.github/workflows/ci.yml`).

## License
MIT
