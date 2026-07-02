#!/bin/bash
# capture.sh — the stream watcher. Launched by live_watch.sh when the channel goes
# live (or run manually). Supervises yt-dlp for up to MAX_STREAM_AGE, riding out
# drops and split streams: Kick closes the HLS manifest cleanly on mid-stream
# crashes (yt-dlp exits 0), so a "clean end" is NOT treated as done for the night —
# the watcher keeps waiting up to MAX_WAIT for a return stream.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUTPUT_TMPL="%(uploader)s %(upload_date>%Y-%m-%d|)s %(title)s [%(id)s].%(ext)s"

# Log rotation: delete logs older than 30 days.
find "$LOG_DIR" -maxdepth 1 -name "*.log" -mtime +30 -delete
MAIN_LOG="$LOG_DIR/capture-main-$(date +%Y-%m-%d_%H-%M-%S).log"
DL_LOG="$LOG_DIR/capture-dl-$(date +%Y-%m-%d_%H-%M-%S).log"

# Fail-closed proxy preflight: if a proxy is configured but down, REFUSE to run.
# Capturing without it would expose the direct IP — the exact thing PROXY_URL
# is there to prevent.
PROXY_ARGS=()
if [ -n "$PROXY_URL" ]; then
    if ! proxy_ok; then
        msg="ABORT: proxy $PROXY_URL unreachable — refusing to capture (fail-closed)."
        echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$MAIN_LOG"
        "$NOTIFY" emergency "Kick capture ABORTED" "$msg" 2>/dev/null || true
        exit 1
    fi
    PROXY_ARGS=(--proxy "$PROXY_URL")
fi

EXEC_ARGS=()
if [ "$CRC_RENAME" = "1" ]; then
    EXEC_ARGS=(--exec "$SCRIPT_DIR/crc_rename.sh {}")
fi

# --- Download function with retry ---
# Usage: download <name> <url> <dir> <live_flag> [extra_ytdlp_args...]
download() {
    local name="$1"
    local url="$2"
    local dir="$3"
    local live_start_flag="$4"
    shift 4
    local extra_args=("$@")
    local start_time
    start_time=$(date +%s)
    local went_live=false
    # Unique temp stamp file for this attempt
    local stamp_file
    stamp_file=$(mktemp -t "capture_attempt_${name}_XXXXXX")
    while true; do
        local now elapsed remaining
        now=$(date +%s)
        elapsed=$((now - start_time))
        remaining=$((MAX_STREAM_AGE - elapsed))
        # Hard stop after MAX_STREAM_AGE
        if [ "$remaining" -le 0 ]; then
            echo "[$name] Max stream age (${MAX_STREAM_AGE}s) reached, exiting."
            break
        fi
        # Timestamp file written immediately before yt-dlp starts.
        # find -newer uses this to detect ONLY .part files from THIS attempt,
        # ignoring all stale .part files from previous interrupted streams.
        touch "$stamp_file"
        echo "[$name] Attempting download at: $url"
        # No timeout wrapper — yt-dlp runs until it finishes or fails naturally.
        "$YTDLP" "$live_start_flag" --wait-for-video "5-${MAX_WAIT}" \
            "${PROXY_ARGS[@]}" --impersonate "$IMPERSONATE" \
            --output "$dir/$OUTPUT_TMPL" \
            "${EXEC_ARGS[@]}" \
            "${extra_args[@]}" \
            "$url"
        local ytdlp_exit=$?
        # went_live detection:
        # Exit 0  = yt-dlp finished cleanly (Kick sent EXT-X-ENDLIST).
        #           This includes mid-stream crashes where Kick closes the HLS
        #           manifest cleanly — yt-dlp exits 0 but the stream may return.
        # .part files newer than stamp = yt-dlp was actively downloading
        #   when it exited, meaning the stream was live and got interrupted.
        # Stale .part files from past runs are ignored (they predate the stamp).
        if [ "$ytdlp_exit" -eq 0 ]; then
            went_live=true
        elif find "$dir" -maxdepth 1 -name "*.part" -newer "$stamp_file" \
                2>/dev/null | grep -q .; then
            went_live=true
        fi
        # yt-dlp polled and stream never started (or return window expired)
        if [ "$went_live" = false ]; then
            echo "[$name] Stream never went live (waited ${MAX_WAIT}s), exiting."
            rm -f "$stamp_file"
            break
        fi
        # Stream was live but ended (exit 0) or dropped (exit non-zero).
        # Either way, loop back — Kick sends exit 0 on mid-stream crashes too,
        # so we can't treat exit 0 as "done for the night." Let --wait-for-video
        # handle re-detection; if the streamer doesn't return within MAX_WAIT the
        # loop exits via the "never went live" path above.
        if [ "$ytdlp_exit" -eq 0 ]; then
            echo "[$name] Stream ended (exit 0), watching for return stream..."
        else
            echo "[$name] Stream dropped (exit $ytdlp_exit), retrying in ${RETRY_DELAY}s..."
        fi
        sleep "$RETRY_DELAY"
    done
    rm -f "$stamp_file"
    echo "[$name] Watcher exited."
}

# --- Run the watcher (backgrounded for a consistent process model) ---
# --no-live-from-start: Kick is forward-only, no DVR rewind.
download "Kick" "$KICK_URL" "$STAGING_DIR" "--no-live-from-start" \
    >> "$DL_LOG" 2>&1 &
wait
echo "$(date '+%Y-%m-%d %H:%M:%S') Kick watcher has exited." | tee -a "$MAIN_LOG"
