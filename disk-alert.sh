#!/usr/bin/env bash
#
# disk-alert.sh - warn when disk usage crosses a threshold.
#
# Checks every mounted filesystem (or only the mount points you list) and
# sends an alert by email and/or Slack-style webhook when usage is too high.
# Designed to run from cron.
#
# Exit codes: 0 = all OK, 1 = warning, 2 = critical, 3 = usage/config error

set -euo pipefail

VERSION="1.0.0"

# ---- Defaults (override with a config file, env vars, or flags) -------------
WARN_THRESHOLD="${WARN_THRESHOLD:-80}"        # percent
CRIT_THRESHOLD="${CRIT_THRESHOLD:-90}"        # percent
MOUNTS="${MOUNTS:-}"                          # space-separated; empty = all
EXCLUDE_FS_TYPES="${EXCLUDE_FS_TYPES:-tmpfs devtmpfs overlay squashfs proc sysfs cgroup cgroup2 efivarfs}"
ALERT_EMAIL="${ALERT_EMAIL:-}"                # e.g. ops@example.com
WEBHOOK_URL="${WEBHOOK_URL:-}"                # Slack / Discord / Teams incoming webhook
LOG_FILE="${LOG_FILE:-}"                      # e.g. /var/log/disk-alert.log
DRY_RUN=false
QUIET=false

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -w, --warn PERCENT      Warning threshold (default: $WARN_THRESHOLD)
  -c, --crit PERCENT      Critical threshold (default: $CRIT_THRESHOLD)
  -m, --mount PATH        Only check this mount point (repeatable)
  -e, --email ADDRESS     Send alerts to this email address
  -u, --webhook URL       Send alerts to this webhook (Slack-compatible JSON)
  -l, --log FILE          Append results to this log file
  -f, --config FILE       Load settings from a config file
  -n, --dry-run           Print alerts instead of sending them
  -q, --quiet             Only print when something is over a threshold
  -h, --help              Show this help
  -v, --version           Show version

Exit codes: 0 OK, 1 warning, 2 critical, 3 error
USAGE
}

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

die() {
    echo "Error: $*" >&2
    exit 3
}

is_percent() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 100 ))
}

# ---- Argument parsing --------------------------------------------------------
CLI_MOUNTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--config)
            [[ -r "${2:-}" ]] || die "cannot read config file: ${2:-<missing>}"
            # shellcheck source=/dev/null
            source "$2"; shift 2 ;;
        -w|--warn)    WARN_THRESHOLD="${2:-}"; shift 2 ;;
        -c|--crit)    CRIT_THRESHOLD="${2:-}"; shift 2 ;;
        -m|--mount)   CLI_MOUNTS+=("${2:-}"); shift 2 ;;
        -e|--email)   ALERT_EMAIL="${2:-}"; shift 2 ;;
        -u|--webhook) WEBHOOK_URL="${2:-}"; shift 2 ;;
        -l|--log)     LOG_FILE="${2:-}"; shift 2 ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -q|--quiet)   QUIET=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        -v|--version) echo "disk-alert $VERSION"; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

if [[ ${#CLI_MOUNTS[@]} -gt 0 ]]; then
    MOUNTS="${CLI_MOUNTS[*]}"
fi

is_percent "$WARN_THRESHOLD" || die "warning threshold must be 0-100, got '$WARN_THRESHOLD'"
is_percent "$CRIT_THRESHOLD" || die "critical threshold must be 0-100, got '$CRIT_THRESHOLD'"
(( WARN_THRESHOLD <= CRIT_THRESHOLD )) || die "warning threshold ($WARN_THRESHOLD) must not exceed critical ($CRIT_THRESHOLD)"

# ---- Alert senders -----------------------------------------------------------
send_email() {
    local subject="$1" body="$2"
    [[ -z "$ALERT_EMAIL" ]] && return 0
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$body" | mail -s "$subject" "$ALERT_EMAIL"
    elif command -v sendmail >/dev/null 2>&1; then
        printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_EMAIL" "$subject" "$body" | sendmail -t
    else
        echo "Warning: no 'mail' or 'sendmail' found; email not sent" >&2
        return 1
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

send_webhook() {
    local text="$1"
    [[ -z "$WEBHOOK_URL" ]] && return 0
    command -v curl >/dev/null 2>&1 || { echo "Warning: curl not found; webhook not sent" >&2; return 1; }
    local escaped
    escaped="$(json_escape "$text")"
    # "text" works for Slack and Teams; "content" for Discord.
    curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"text\":\"$escaped\",\"content\":\"$escaped\"}" \
        "$WEBHOOK_URL" >/dev/null \
        || { echo "Warning: webhook request failed" >&2; return 1; }
}

# ---- Disk check --------------------------------------------------------------
# Prints lines: "<use%> <mount> <size> <used> <avail> <fstype>"
collect_usage() {
    local exclude_args=() t
    for t in $EXCLUDE_FS_TYPES; do
        exclude_args+=(-x "$t")
    done
    # shellcheck disable=SC2086
    df -P -h -T "${exclude_args[@]}" $MOUNTS 2>/dev/null \
        | awk 'NR > 1 { gsub("%", "", $6); print $6, $7, $3, $4, $5, $2 }'
}

main() {
    local usage_lines status=0 alerts="" level
    usage_lines="$(collect_usage)" || true
    [[ -n "$usage_lines" ]] || die "no filesystems found (check --mount paths)"

    while read -r pct mount size used avail fstype; do
        if (( pct >= CRIT_THRESHOLD )); then
            level="CRITICAL"; (( status < 2 )) && status=2
        elif (( pct >= WARN_THRESHOLD )); then
            level="WARNING";  (( status < 1 )) && status=1
        else
            level="OK"
        fi

        local line
        line="$(printf '%-8s %3s%%  %-20s used %s of %s (%s free, %s)' \
            "$level" "$pct" "$mount" "$used" "$size" "$avail" "$fstype")"

        if [[ "$level" != "OK" ]]; then
            alerts+="$line"$'\n'
        fi
        if [[ "$level" != "OK" || "$QUIET" == false ]]; then
            echo "$line"
        fi
        log "$line"
    done <<< "$usage_lines"

    if (( status > 0 )); then
        local word subject body
        word=$([[ $status -eq 2 ]] && echo "CRITICAL" || echo "WARNING")
        subject="[disk-alert] $word on $HOSTNAME_SHORT"
        body="Disk usage alert on $HOSTNAME_SHORT ($(date '+%Y-%m-%d %H:%M:%S'))
Thresholds: warn ${WARN_THRESHOLD}%, critical ${CRIT_THRESHOLD}%

${alerts}"
        if [[ "$DRY_RUN" == true ]]; then
            echo
            echo "---- dry run: alert that would be sent ----"
            echo "Subject: $subject"
            echo "$body"
        else
            send_email "$subject" "$body" || true
            send_webhook "$subject"$'\n'"$alerts" || true
        fi
    fi

    return "$status"
}

main
