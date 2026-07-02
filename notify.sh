#!/bin/bash
# notify.sh — single alert entry point. Channel + tokens come from capture.conf
# (chmod 600, gitignored). Alerts go DIRECT to the provider (NOT through the Kick
# proxy) — only Kick traffic needs to avoid the direct IP.
#
# Usage: notify.sh <normal|emergency> <title> <message>
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PRIORITY="${1:-normal}"; TITLE="${2:-kick-live-capture}"; MSG="${3:-}"
LOG="$LOG_DIR/notify-$(date +%Y-%m-%d).log"
nlog(){ echo "$(date '+%F %T') [$PRIORITY] $TITLE :: $MSG${1:+ | }${1:-}" >> "$LOG"; }

case "$NOTIFY_CHANNEL" in
  pushover)
    prio=0; extra=()
    if [ "$PRIORITY" = "emergency" ]; then
        # priority 2 = retry until acknowledged
        prio=2; extra=(--data-urlencode "retry=60" --data-urlencode "expire=3600")
    fi
    if curl -s --max-time 20 \
        --data-urlencode "token=${PUSHOVER_APP_TOKEN:-}" \
        --data-urlencode "user=${PUSHOVER_USER_KEY:-}" \
        --data-urlencode "title=${TITLE}" \
        --data-urlencode "message=${MSG}" \
        --data-urlencode "priority=${prio}" \
        "${extra[@]}" \
        https://api.pushover.net/1/messages.json | grep -q '"status":1'; then
        nlog "sent via pushover"
    else
        nlog "PUSHOVER SEND FAILED"
    fi
    ;;
  ntfy)
    pr="default"; [ "$PRIORITY" = "emergency" ] && pr="urgent"
    if curl -s --max-time 20 -H "Title: ${TITLE}" -H "Priority: ${pr}" -H "Tags: warning" \
        -d "${MSG}" "${NTFY_URL:-}" >/dev/null; then
        nlog "sent via ntfy"
    else
        nlog "NTFY SEND FAILED"
    fi
    ;;
  none|*)
    nlog "no channel configured (set NOTIFY_CHANNEL in capture.conf) — logged only"
    ;;
esac
