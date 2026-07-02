# kick-live-capture

Always-watching capture for a [Kick](https://kick.com) channel. A cron poll-launcher
checks every couple of minutes whether the channel is live; the moment it is, a
supervised yt-dlp watcher starts recording, rides out drops and split streams, and
(optionally) rsyncs finished files to an archive server with verify-then-delete.
A watchdog makes every failure loud via Pushover or ntfy.

Built for the case where **the live capture is the authoritative archive**: Kick is
forward-only (no DVR rewind), so every minute of detection latency is footage lost
permanently, and VODs are not a guaranteed backstop.

## How it works

```
cron ─▶ live_watch.sh ──poll──▶ islive.py ──▶ kick.com API (optionally via SOCKS5)
              │                                      │
              │ 200|true                             ▼
              ├──────────▶ capture.sh ──▶ yt-dlp ──▶ STAGING_DIR ──▶ crc_rename.sh
              │
              ▼ heartbeat every tick
cron ─▶ watchdog.sh ──▶ emergency alert on: stale poller / proxy down /
              ban signature (403/429/503) / sustained timeouts / unparseable API
cron ─▶ deliver.sh ──▶ rsync to DELIVER_REMOTE ──▶ checksum verify ──▶ delete local
```

- **`live_watch.sh`** — poll-launcher. flock single-instance, 0–8 s random jitter
  (polls don't look machine-periodic), writes a heartbeat every tick. While a capture
  is running it skips the API poll entirely and just refreshes the heartbeat
  (`downloading` vs `waiting`, judged by recent write activity in the staging dir).
- **`islive.py`** — is_live probe using [curl_cffi](https://github.com/lexiforest/curl_cffi)
  browser impersonation so Cloudflare's bot check passes.
- **`capture.sh`** — the watcher. Supervises yt-dlp for up to `MAX_STREAM_AGE`
  (default 30 h). Kick closes the HLS manifest cleanly on mid-stream crashes, so a
  "clean end" is deliberately *not* treated as done for the night — the watcher keeps
  waiting up to `MAX_WAIT` for a return stream (split-stream recovery).
- **`watchdog.sh`** — separate cron so a dead poller can't silence its own alarm.
  Debounced: transient timeouts / unparseable responses only page after
  `FAIL_THRESHOLD` consecutive bad polls; ban signatures and proxy-down page
  immediately. Alarms once, then one recovery note.
- **`deliver.sh`** — optional. Never deletes a local file until an rsync
  `--checksum` dry-run confirms the remote copy byte-for-byte. A verify run that
  *errors* is a failure, never a pass.
- **`crc_rename.sh`** — optional yt-dlp post-processor appending a CRC32 to finished
  filenames (requires `rhash`).

## Requirements

- Linux with bash, cron, `flock`, `timeout`, `rsync` (Debian/Ubuntu: all standard)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) with curl_cffi support
  (`yt-dlp[default,curl-cffi]` or the standalone binary) — `--impersonate` must work
- Python 3 with `curl_cffi` (`pip install curl_cffi`)
- Optional: `rhash` for CRC renaming, an SSH-reachable box for delivery,
  a [Pushover](https://pushover.net) or [ntfy](https://ntfy.sh) account for alerts

## Setup

```bash
git clone https://github.com/shadypayload/kick-live-capture.git
cd kick-live-capture
cp capture.conf.example capture.conf
chmod 600 capture.conf
$EDITOR capture.conf        # set CHANNEL at minimum
```

Test the pieces by hand first:

```bash
KICK_CHANNEL=yourchannel ./islive.py; echo         # expect 200|true or 200|false
./live_watch.sh && cat "$HOME/kick_capture/state/heartbeat"
./notify.sh normal "test" "hello"                  # then check logs/notify-*.log
```

Then wire up cron (`crontab -e`). Example — tight polling during likely stream
hours, relaxed overnight:

```cron
*/2  10-23 * * *  /path/to/kick-live-capture/live_watch.sh
*/2  0-2   * * *  /path/to/kick-live-capture/live_watch.sh
*/12 3-9   * * *  /path/to/kick-live-capture/live_watch.sh
*/5  *     * * *  /path/to/kick-live-capture/watchdog.sh
17   *     * * *  /path/to/kick-live-capture/deliver.sh   # only if DELIVER_REMOTE set
0    3     * * *  yt-dlp -U   # keep impersonation targets fresh (standalone binary)
```

Poll cadence is a latency-vs-rate-limit tradeoff. Every minute of detection latency
is footage lost (no rewind), but don't hammer the API either — 2 min with jitter has
been reliable.

## Optional: SOCKS5 proxy (fail-closed)

If you don't want your home IP touching Kick, set `PROXY_URL` and every script —
poll *and* capture — egresses through that proxy. The design is **fail-closed**: when
the proxy is unreachable, the scripts refuse to touch Kick at all (heartbeat records
`proxy_down`, the watchdog pages you) rather than falling back to your direct IP.

A cheap VPS + SSH dynamic tunnel works well, kept alive by systemd:

```ini
# /etc/systemd/system/kick-tunnel.service
[Unit]
Description=SOCKS5 tunnel for kick-live-capture
After=network-online.target

[Service]
User=youruser
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -D 127.0.0.1:1080 -o BatchMode=yes \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 your-vps
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Then `PROXY_URL="socks5://localhost:1080"`. DNS is resolved proxy-side too
(`socks5h`), so there's no local DNS leak. Verify egress:

```bash
curl -s --socks5-hostname localhost:1080 https://api.ipify.org   # must be the VPS IP
```

## Heartbeat format

`$STATE_DIR/heartbeat` is one line: `epoch|iso8601|http_status|value|note`

| Line ends with | Meaning |
|---|---|
| `200\|false` | healthy, channel offline |
| `200\|true` | live — capture launching |
| `200\|true\|downloading` | capture actively writing |
| `200\|true\|waiting` | watcher alive, idling for a split-stream return |
| `0\|?\|proxy_down` | proxy unreachable — fail-closed, not polling |
| `403/429/503\|degraded` | ban signature — watchdog pages immediately |
| `0\|err:*` | timeout/network error — pages after `FAIL_THRESHOLD` in a row |
| `200\|parse_err:*` | API reached but response unparseable (schema change / CF interstitial served as 200) — pages after `FAIL_THRESHOLD` in a row |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Heartbeat `proxy_down` | Tunnel down. Restart it; capture is blind-but-safe until it's back. |
| Probe returns `403/429/503` | Cloudflare / rate-limit / possible ban. Back off; widen the poll interval; update yt-dlp + curl_cffi so the impersonation target is current. |
| Occasional `0\|err:Timeout` | Kick/Cloudflare being slow. Singles are benign (debounced); a sustained run (≥`FAIL_THRESHOLD`, ~6 min) pages and means a real path problem. |
| `200\|parse_err:*` | Kick changed the API response shape, or Cloudflare served an interstitial with HTTP 200. Check `curl https://kick.com/api/v2/channels/<channel>` and update `islive.py` if the schema moved. |
| Delivery "VERIFY RSYNC FAILED" | The checksum dry-run errored (SSH drop / remote down) — the local copy is kept and retried next cycle. The transfer itself likely succeeded; the alarm is about the *check*. |
| Delivery "VERIFY MISMATCH" | Remote bytes differ from local. Local copy is kept. Investigate disk/network before re-sending. |
| Watcher runs but no file appears | Watch `logs/capture-dl-*.log` during a stream; confirm `--impersonate` still passes Kick's bot check (update yt-dlp). |

## Design notes

- **Sticky `went_live` + 30 h cap are intentional.** Once a stream has been seen live,
  the watcher never concludes "done for the night" from a clean yt-dlp exit — Kick
  ends the manifest cleanly on crashes too. It waits `MAX_WAIT` for a return stream
  each time, and only the `MAX_STREAM_AGE` cap ends the watcher's life. Split streams
  land as multiple files from one watcher.
- **The launcher closes its lock FD (`9>&-`) when spawning the watcher.** Otherwise
  the multi-hour capture inherits the flock, every later poll tick skips, the
  heartbeat goes stale, and the watchdog false-alarms all stream long.
- **Watchdog and poller are separate cron jobs** so the failure detector doesn't
  share fate with the thing it's watching.

## License

MIT — see [LICENSE](LICENSE).
