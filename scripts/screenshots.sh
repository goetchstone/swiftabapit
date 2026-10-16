#!/usr/bin/env bash
# Renders every screen of a debug abapit.app to PNGs (plan §6.5), from the demo org only: strict stubs and
# memory, never the Keychain or a real tenant. CI's macOS job runs it; never run it on the operator's
# screen (it opens windows). The sandboxed app writes each picture inside its container and prints the
# path; this script moves it to the output folder. Adapted from SwiftGamGui scripts/screenshots.sh @ bfdb494.
#
#   scripts/screenshots.sh path/to/Debug/abapit.app out-dir
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/screenshots.sh path/to/abapit.app out-dir}"
out="${2:?usage: scripts/screenshots.sh path/to/abapit.app out-dir}"
binary="$app/Contents/MacOS/abapit"
[ -x "$binary" ] || { echo "no executable at $binary" >&2; exit 1; }
mkdir -p "$out"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

status=0
# name:section[:selected[:window]] — the narrow-* runs open a section in the smallest window with the
# sidebar dragged to its widest, where SwiftGamGui's narrow-window layout loop crashed AppKit (its
# failure-log 2026-10-10): they fail when the pane has too little room to spare, and on any non-zero exit.
for spec in overview:overview devices:devices people:people content:content activity:activity \
            reports:reports settings:settings narrow-overview:overview::smallest; do
  IFS=: read -r name section selected window <<< "$spec"
  file="$out/$name.png"
  rm -f "$file"
  : > "$log"
  env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    ABAPIT_DEMO=1 ABAPIT_SCREEN="$section" ABAPIT_SNAPSHOT="$name.png" \
    ${selected:+ABAPIT_SELECT="$selected"} ${window:+ABAPIT_WINDOW="$window"} "$binary" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  hung=0
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; hung=1; echo "::error::$name: no snapshot within 60 s" >&2; status=1; fi
  code=0; wait "$pid" || code=$?
  cat "$log"
  if [ "$hung" = 0 ] && [ "$code" != 0 ]; then echo "::error::$name: abapit exited with status $code" >&2; status=1; fi
  written="$(sed -nE 's/^snapshot: (\/.*\.png)$/\1/p' "$log" | tail -1)"
  if [ -n "$written" ] && [ -s "$written" ]; then mv "$written" "$file"; echo "$name: $file"; else echo "::error::$name: no image written" >&2; status=1; fi
done
exit "$status"
