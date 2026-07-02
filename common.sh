# common.sh — sourced by every script: loads capture.conf, applies defaults,
# and provides shared helpers. Not executable on its own.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/capture.conf"
if [ ! -f "$CONF" ]; then
    echo "ERROR: $CONF not found — copy capture.conf.example to capture.conf and edit it." >&2
    exit 1
fi
. "$CONF"

: "${CHANNEL:?CHANNEL must be set in capture.conf}"
STAGING_DIR="${STAGING_DIR:-$HOME/kick_capture}"
LOG_DIR="${LOG_DIR:-$STAGING_DIR/logs}"
STATE_DIR="${STATE_DIR:-$STAGING_DIR/state}"
PROXY_URL="${PROXY_URL:-}"
YTDLP="${YTDLP:-yt-dlp}"
IMPERSONATE="${IMPERSONATE:-chrome}"
MAX_WAIT="${MAX_WAIT:-1500}"
RETRY_DELAY="${RETRY_DELAY:-5}"
MAX_STREAM_AGE="${MAX_STREAM_AGE:-108000}"
CRC_RENAME="${CRC_RENAME:-0}"
STALE_SECS="${STALE_SECS:-900}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
DELIVER_REMOTE="${DELIVER_REMOTE:-}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-none}"

KICK_URL="https://kick.com/$CHANNEL"
HEARTBEAT="$STATE_DIR/heartbeat"          # epoch|iso|http_status|value|note
CONSEC_FAIL="$STATE_DIR/consec_fail"      # consecutive bad-poll streak (watchdog debounce)
WATCHER="$SCRIPT_DIR/capture.sh"
NOTIFY="$SCRIPT_DIR/notify.sh"
ISLIVE="$SCRIPT_DIR/islive.py"

mkdir -p "$STAGING_DIR" "$LOG_DIR" "$STATE_DIR"

# Callers set LOG to their own file before using this.
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# TCP preflight to the SOCKS5 proxy. Only meaningful when PROXY_URL is set.
# Returns nonzero when the proxy is unreachable — callers must then REFUSE to
# touch Kick (fail-closed), never fall back to the direct IP.
proxy_ok(){
    local hostport host port
    hostport="${PROXY_URL#*://}"; hostport="${hostport%%/*}"
    host="${hostport%%:*}"; port="${hostport##*:}"
    [ -n "$host" ] && [ -n "$port" ] || return 1
    timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}
