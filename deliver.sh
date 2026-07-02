#!/bin/bash
# deliver.sh — move finished captures to a remote archive over rsync, then
# verify-then-delete. NEVER deletes a local copy until the remote copy is
# byte-verified. Optional: does nothing unless DELIVER_REMOTE is set.
#
# Verify strategy: rsync the file, then re-run rsync with --checksum in
# itemize/dry-run mode; if it reports the file would still transfer, the bytes
# differ -> keep local + alarm. If the dry-run itself errors, that is NOT a
# pass — local kept + alarm.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ -n "$DELIVER_REMOTE" ] || exit 0

LOG="$LOG_DIR/deliver-$(date +%Y-%m-%d).log"
LOCK="$STATE_DIR/deliver.lock"

exec 9>"$LOCK"
flock -n 9 || { log "deliver already running; skip"; exit 0; }

# Never move while a capture is in progress.
if pgrep -f "$WATCHER" >/dev/null 2>&1; then
    log "watcher running — skipping delivery this cycle"
    exit 0
fi

[ -d "$STAGING_DIR" ] || { log "no capture dir yet ($STAGING_DIR)"; exit 0; }

shopt -s nullglob
moved=0; failed=0; seen=0
for f in "$STAGING_DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in
        *.part|*.ytdl|*.json|*.webp|*.temp|*.tmp) continue ;;
    esac
    # Stability guard: skip anything modified in the last 5 min (may still be active).
    if [ -n "$(find "$f" -mmin -5 2>/dev/null)" ]; then
        log "skip (recently modified): $(basename "$f")"
        continue
    fi
    seen=$((seen+1))
    base=$(basename "$f")
    log "delivering: $base"
    if ! rsync -a --partial --inplace "$f" "$DELIVER_REMOTE/" 2>>"$LOG"; then
        log "RSYNC FAILED (keeping local): $base"
        "$NOTIFY" emergency "Capture delivery FAILED" "rsync to $DELIVER_REMOTE failed for $base — local copy kept." || true
        failed=$((failed+1)); continue
    fi
    # Verify: a checksum dry-run must report NO transfer for this file. The dry-run
    # itself failing (SSH drop, remote down) is NOT a pass — "no diff reported" only
    # counts when the check actually ran, otherwise the local copy would be deleted
    # unverified.
    verify_out=$(rsync -ain --checksum "$f" "$DELIVER_REMOTE/" 2>>"$LOG")
    verify_rc=$?
    if [ "$verify_rc" -ne 0 ]; then
        log "VERIFY RSYNC FAILED rc=$verify_rc (keeping local): $base"
        "$NOTIFY" emergency "Capture delivery verify FAILED" "Verify rsync errored (rc=$verify_rc) for $base — could not confirm remote copy; local kept." || true
        failed=$((failed+1)); continue
    fi
    verify=$(printf '%s\n' "$verify_out" | awk 'NF' | grep -E '^[<>ch]' || true)
    if [ -z "$verify" ]; then
        rm -f "$f"
        log "VERIFIED + removed local: $base"
        moved=$((moved+1))
    else
        log "VERIFY MISMATCH (keeping local): $base :: $verify"
        "$NOTIFY" emergency "Capture delivery verify FAILED" "Checksum mismatch after rsync for $base — local kept. Investigate before it's lost." || true
        failed=$((failed+1))
    fi
done
[ "$seen" -gt 0 ] && log "deliver done: moved=$moved failed=$failed (of $seen candidates)"
exit 0
