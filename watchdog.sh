#!/bin/bash
# watchdog.sh — makes failure LOUD (run from cron, separate from the launcher).
# Alarms (emergency notification) when:
#   - no successful poll heartbeat in STALE_SECS  (poller dead / cron not firing / box hung)
#   - the proxy is down                            (capture is BLIND, fail-closed)
#   - the last poll returned a ban signature       (403/429/503)
#   - a sustained run of timeouts or unparseable-200s (debounced by FAIL_THRESHOLD)
# De-bounced: alarms once, then stays quiet until it recovers (then sends one recovery note).
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ALARM_STATE="$STATE_DIR/watchdog_alarmed"
LOG="$LOG_DIR/watchdog-$(date +%Y-%m-%d).log"

now=$(date +%s)

if [ ! -f "$HEARTBEAT" ]; then
    log "no heartbeat file yet — poller has not run; not alarming on first boot"
    exit 0
fi

IFS='|' read -r hb_epoch hb_iso hb_status hb_value hb_note < "$HEARTBEAT"
[ -n "${hb_epoch:-}" ] || { log "heartbeat unreadable"; exit 0; }
age=$(( now - hb_epoch ))

# A stale heartbeat is EXPECTED and benign while a capture runs (defense in depth —
# normally the launcher keeps refreshing it even then). Only treat staleness as a
# fault when NO capture is active.
capture_running=false
if pgrep -f "$WATCHER" >/dev/null 2>&1; then capture_running=true; fi
if [ "$age" -gt "$STALE_SECS" ] && [ "$capture_running" = true ]; then
    log "heartbeat stale (${age}s) but a capture is actively running — healthy, suppressing stale alarm"
fi

# Consecutive-failure streak (maintained by the poller). Used to debounce transient
# Kick slowness so a single slow poll doesn't page — but a sustained outage still does.
consec=$(cat "$CONSEC_FAIL" 2>/dev/null || echo 0)
case "$consec" in (*[!0-9]*|"") consec=0 ;; esac

problem=""
if [ "$age" -gt "$STALE_SECS" ] && [ "$capture_running" != true ]; then
    problem="No successful poll in ${age}s (limit ${STALE_SECS}s). Poller/cron/box may be dead. Last heartbeat $hb_iso (status=$hb_status value=$hb_value note=$hb_note)."
elif [ "$hb_note" = "proxy_down" ]; then
    problem="SOCKS5 proxy is DOWN — capture is BLIND (fail-closed, not polling on the direct IP). Last check $hb_iso."
elif [ "$hb_status" = "0" ]; then
    # Timeout / DNS / proxy-side network error. Debounced: only alarm once the poller
    # has logged FAIL_THRESHOLD back-to-back failures, so brief Kick/Cloudflare
    # slowness stays quiet.
    if [ "$consec" -ge "$FAIL_THRESHOLD" ]; then
        problem="Kick poll timing out on $consec consecutive polls (detail=$hb_value). Path/proxy may be degraded. Last check $hb_iso."
    else
        log "transient Kick timeout ($consec/$FAIL_THRESHOLD consecutive, detail=$hb_value) — within debounce, not alarming"
    fi
elif [ "$hb_status" != "200" ]; then
    problem="Kick poll returned HTTP $hb_status (possible rate-limit / Cloudflare / ban). Last check $hb_iso note=$hb_note."
elif [ "$hb_value" != "true" ] && [ "$hb_value" != "false" ]; then
    # HTTP 200 but the body didn't parse to a live boolean — Cloudflare interstitial
    # served with a 200, or the Kick API schema changed. Without this branch a schema
    # change would silently kill live detection with the watchdog reporting healthy.
    # Debounced on the same streak as timeouts (the poller counts these too).
    if [ "$consec" -ge "$FAIL_THRESHOLD" ]; then
        problem="Kick poll returns HTTP 200 with unparseable body on $consec consecutive polls (detail=$hb_value). Possible API schema change or Cloudflare interstitial — live detection is blind. Last check $hb_iso."
    else
        log "transient unparseable 200 ($consec/$FAIL_THRESHOLD consecutive, detail=$hb_value) — within debounce, not alarming"
    fi
fi

if [ -n "$problem" ]; then
    log "ALARM: $problem"
    if [ ! -f "$ALARM_STATE" ]; then
        "$NOTIFY" emergency "Kick capture DEGRADED" "$problem" || true
        date '+%F %T' > "$ALARM_STATE"
    else
        log "(already alarmed; suppressing duplicate)"
    fi
else
    if [ -f "$ALARM_STATE" ]; then
        "$NOTIFY" normal "Kick capture RECOVERED" "Polls healthy again at $(date '+%F %T') (status=$hb_status value=$hb_value)." || true
        rm -f "$ALARM_STATE"
    fi
    log "healthy: age=${age}s status=$hb_status value=$hb_value"
fi
