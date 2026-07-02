#!/usr/bin/env python3
# islive.py — probe Kick's channel API for is_live, optionally through a SOCKS5 proxy.
#
# Uses curl_cffi (browser impersonation) so Cloudflare's bot check passes. Channel and
# proxy come from the environment (set by live_watch.sh):
#   KICK_CHANNEL  — channel slug (required)
#   KICK_PROXY    — SOCKS5 proxy URL, empty/unset = direct connection
#
# Output (single line on stdout): <http_status>|<value>
#   200|true   -> channel is live
#   200|false  -> API reached, not live
#   <code>|degraded / 0|err:* / 200|parse_err:*  -> something wrong (ban/CF/network/schema)
# Exit codes: 0 = definitive answer (true/false). 2 = degraded (caller treats as alarm).
import os
import sys

CHANNEL = os.environ.get("KICK_CHANNEL", "").strip()
if not CHANNEL:
    sys.stdout.write("0|err:no_channel")
    sys.exit(2)

PROXY = os.environ.get("KICK_PROXY", "").strip()
if PROXY.startswith("socks5://"):
    # socks5h => DNS is resolved on the proxy side too (no local DNS leak)
    PROXY = "socks5h://" + PROXY[len("socks5://"):]

URL = f"https://kick.com/api/v2/channels/{CHANNEL}"

try:
    from curl_cffi import requests
except Exception:
    sys.stdout.write("0|err:no_curl_cffi")
    sys.exit(2)

try:
    r = requests.get(
        URL,
        impersonate=os.environ.get("KICK_IMPERSONATE", "chrome"),
        proxies={"http": PROXY, "https": PROXY} if PROXY else None,
        timeout=30,  # ride out slow Cloudflare challenges before calling it a timeout
    )
except Exception as e:
    sys.stdout.write(f"0|err:{type(e).__name__}")
    sys.exit(2)

status = r.status_code
if status != 200:
    # 403/429/503 = Cloudflare challenge / rate-limit / ban signature
    sys.stdout.write(f"{status}|degraded")
    sys.exit(2)

try:
    data = r.json()
    ls = data.get("livestream")
    is_live = bool(ls and ls.get("is_live"))
    sys.stdout.write(f"200|{'true' if is_live else 'false'}")
    sys.exit(0)
except Exception as e:
    sys.stdout.write(f"200|parse_err:{type(e).__name__}")
    sys.exit(2)
