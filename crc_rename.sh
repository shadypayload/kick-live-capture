#!/bin/bash
# crc_rename.sh - Streaming CRC32 + safe for live stream retries + deletes .info.json
# Used as a yt-dlp --exec post-processor (enable with CRC_RENAME=1). Requires rhash.

[[ -z "$1" ]] && { echo "Usage: $0 <file>"; exit 1; }

python3 - "$1" <<'PY'
import os, sys, re, subprocess

f = sys.argv[1]

# Skip temp/metadata files (yt-dlp handles .webp)
if f.lower().endswith(('.part', '.ytdl', '.json', '.webp')):
    sys.exit(0)

try:
    base, ext = os.path.splitext(f)
    # Strip any existing [CRC] so retries never double-stack
    clean_base = re.sub(r' \[[A-Fa-f0-9]{8}\]$', '', base)
    json_file = clean_base + '.info.json'

    result = subprocess.run(['rhash', '--crc32', '--printf=%C', f], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    crc_hex = result.stdout.strip().upper()

    new_name = f"{clean_base} [{crc_hex}]{ext}"

    if new_name == f:
        print(f"[CRC] Already good: {os.path.basename(f)}")
        if os.path.exists(json_file):
            os.remove(json_file)
        sys.exit(0)

    # Collision (common on watcher retries)
    if os.path.exists(new_name):
        print(f"[CRC] Collision - skipping rename: {os.path.basename(new_name)}")
        if os.path.exists(json_file):
            os.remove(json_file)
        sys.exit(0)

    # Normal case: rename video FIRST, then delete .info.json
    os.rename(f, new_name)
    print(f"[CRC] → {os.path.basename(new_name)}")
    if os.path.exists(json_file):
        os.remove(json_file)

except Exception as e:
    print(f"[CRC] Error with {f}: {e}", file=sys.stderr)
    sys.exit(1)
PY
