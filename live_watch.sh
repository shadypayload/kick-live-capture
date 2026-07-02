#!/bin/bash
# live_watch.sh — the poll-launcher (run from cron every few minutes).
# Polls Kick's is_live (through the proxy when one is configured); launches capture.sh
# when the channel goes live and no watcher is already running. Writes a heartbeat
# every tick for the watchdog.
#
# Fail-closed: if a proxy is configured but unreachable we do NOT poll Kick at all.
# That is recorded as a degraded heartbeat so the watchdog alarms.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LOCK="$STATE_DIR/live_watch.lock"
LOG="$LOG_DIR/live_watch-$(date +%Y-%m-%d).log"
write_hb(){ printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$(date '+%FT%T%z')" "$1" "$2" "${3:-}" > "$HEARTBEAT"; }

# One launcher tick at a time; if the previous tick is still going, skip this one.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "previous tick still running; skipping"
    exit 0
fi

# Small random jitter so polls are not perfectly periodic (look human).
sleep $(( RANDOM % 8 ))

# Fail-closed proxy preflight — if a proxy is configured but down, do NOT poll Kick.
if [ -n "$PROXY_URL" ] && ! proxy_ok; then
    log "PROXY DOWN ($PROXY_URL unreachable) — not polling (fail-closed)"
    write_hb "0" "?" "proxy_down"
    exit 0
fi

# If a capture is already running we ALREADY know the channel is live. Don't re-poll
# Kick every tick for the whole (multi-hour) stream — just keep the heartbeat fresh so
# the watchdog knows the poller is alive, then bail. (Proxy preflight above still runs
# first, so a tunnel drop mid-capture is still caught and alarmed.)
if pgrep -f "$WATCHER" >/dev/null 2>&1; then
    # A watcher process exists, but it's in one of two states: actively downloading, OR
    # just idle-polling for a split-stream return (yt-dlp --wait-for-video). Distinguish
    # them by recent write activity in the staging dir, so the heartbeat doesn't claim
    # it's capturing while the channel is actually offline. A fresh write to ANY file
    # (the growing .part, or a just-finished .mp4) in the last 2 min = downloading;
    # otherwise it's waiting for the stream to (re)appear. The ~2min window tolerates
    # the brief no-write gap between a clean ENDLIST and the next segment in a split
    # stream.
    if find "$STAGING_DIR" -maxdepth 1 -type f -mmin -2 2>/dev/null | grep -q .; then
        hb_note="downloading"
    else
        hb_note="waiting"
    fi
    write_hb "200" "true" "$hb_note"
    echo 0 > "$CONSEC_FAIL"   # a running watcher is healthy — clear any failure streak
    log "watcher running ($hb_note) — heartbeat refreshed; skipping Kick poll"
    exit 0
fi

OUT=$(KICK_CHANNEL="$CHANNEL" KICK_PROXY="$PROXY_URL" KICK_IMPERSONATE="$IMPERSONATE" "$ISLIVE"); RC=$?
# A hard-killed probe (OOM, segfault) emits nothing; normalize so the heartbeat stays
# well-formed and the timeout debounce below handles it like any other status=0 error.
[ -n "$OUT" ] || { OUT="0|err:empty_probe_output"; RC=2; }
STATUS="${OUT%%|*}"
VALUE="${OUT#*|}"
write_hb "$STATUS" "$VALUE" ""
log "poll: status=$STATUS value=$VALUE rc=$RC"

# Maintain the consecutive-failure streak for the watchdog's debounce. Debounced kinds:
# status=0 (timeout / DNS / proxy-side network error) AND 200-with-unparseable-body
# (Cloudflare interstitial served as 200, or a Kick API schema change). HTTP ban codes
# (403/429/503) and proxy_down still alarm immediately via the watchdog. Only a
# definitive 200 true/false resets the streak.
if [ "$STATUS" = "200" ] && { [ "$VALUE" = "true" ] || [ "$VALUE" = "false" ]; }; then
    echo 0 > "$CONSEC_FAIL"
elif [ "$STATUS" = "0" ] || [ "$STATUS" = "200" ]; then
    echo $(( $(cat "$CONSEC_FAIL" 2>/dev/null || echo 0) + 1 )) > "$CONSEC_FAIL"
fi

if [ "$RC" -ne 0 ]; then
    # Degraded (ban/CF/timeout). Heartbeat carries it; the watchdog raises the alarm.
    log "DEGRADED probe (status=$STATUS detail=$VALUE)"
    exit 0
fi

if [ "$VALUE" = "true" ]; then
    if pgrep -f "$WATCHER" >/dev/null 2>&1; then
        log "live=true but a watcher is already running — nothing to do"
        exit 0
    fi
    log "LIVE detected, no watcher running -> launching capture.sh"
    "$NOTIFY" normal "Channel LIVE — launching capture" "$CHANNEL is_live=true at $(date '+%F %T'); capture starting." || true
    # 9>&- : close the inherited flock FD in the child so the launcher lock is NOT held
    # hostage for the entire capture. Without this the child (capture.sh/yt-dlp) keeps
    # FD 9 open, the lock never releases, every later tick skips, and the heartbeat goes
    # stale → the watchdog false-alarms for the whole stream.
    setsid "$WATCHER" >/dev/null 2>&1 9>&- &
    log "launched capture.sh (pid $!)"
fi
exit 0
