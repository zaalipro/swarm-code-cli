#!/usr/bin/env bash
# Render a page with headless Google Chrome and save a PNG.
#
#   scripts/dev/companion_screenshot.sh <url-or-file> <out.png> [width height]
#
# Uses a throwaway --user-data-dir under /tmp that is deleted afterwards, so
# the user's real browser profile, cookies and sessions are never touched.
#
# Chrome's new headless mode sometimes keeps running after it has written the
# screenshot (pages with timers), so Chrome is run in the background and
# stopped once the PNG has appeared and stopped growing.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <url-or-file> <out.png> [width height]" >&2
  exit 2
fi

target="$1"
out="$2"
width="${3:-1440}"
height="${4:-1100}"

chrome="${COMPANION_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$chrome" ]; then
  echo "Google Chrome not found at: $chrome" >&2
  echo "Set COMPANION_CHROME to the binary path." >&2
  exit 1
fi

# A bare path becomes a file:// URL; anything with a scheme is passed through.
case "$target" in
  http://*|https://*|file://*) url="$target" ;;
  *)
    if [ ! -e "$target" ]; then
      echo "no such file: $target" >&2
      exit 1
    fi
    abs="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    url="file://$abs"
    ;;
esac

case "$out" in
  /*) out_abs="$out" ;;
  *) out_abs="$(pwd)/$out" ;;
esac
mkdir -p "$(dirname "$out_abs")"
rm -f "$out_abs"

profile="$(mktemp -d /tmp/companion-chrome-profile.XXXXXX)"
chrome_pid=""

cleanup() {
  if [ -n "$chrome_pid" ] && kill -0 "$chrome_pid" 2>/dev/null; then
    kill "$chrome_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$chrome_pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$chrome_pid" 2>/dev/null || true
  fi
  # Helper processes of this profile only; never any other Chrome.
  pkill -f -- "--user-data-dir=$profile" 2>/dev/null || true
  rm -rf "$profile"
}
trap cleanup EXIT

"$chrome" \
  --headless=new \
  --disable-gpu \
  --hide-scrollbars \
  --no-first-run \
  --no-default-browser-check \
  --user-data-dir="$profile" \
  --window-size="${width},${height}" \
  --virtual-time-budget=2500 \
  --timeout=20000 \
  --screenshot="$out_abs" \
  "$url" >/dev/null 2>&1 &
chrome_pid=$!

# Wait up to 40 s for the PNG, then until its size is stable for two ticks.
deadline=$((SECONDS + 40))
last=-1
stable=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -s "$out_abs" ]; then
    size=$(stat -f %z "$out_abs" 2>/dev/null || stat -c %s "$out_abs")
    if [ "$size" = "$last" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 2 ] && break
    else
      stable=0
      last=$size
    fi
  fi
  if ! kill -0 "$chrome_pid" 2>/dev/null; then
    [ -s "$out_abs" ] && break
    echo "chrome exited without writing $out_abs" >&2
    exit 1
  fi
  sleep 0.25
done

if [ ! -s "$out_abs" ]; then
  echo "no screenshot written to $out_abs within 40 s" >&2
  exit 1
fi
echo "$out_abs"
