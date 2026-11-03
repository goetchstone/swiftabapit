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
marker="$(mktemp)"
trap 'rm -f "$log" "$marker"' EXIT

# A run that dies without a word (a precondition inside an optimized framework traps silently: PR 12's narrow People
# run): the report macOS writes for it, so the log says where. Its exception, Apple's application-specific
# information and the crashed thread's top frames; nothing else of the report, which holds no tenant data in the demo.
crash_report() {
  local report=""
  for _ in $(seq 15); do
    for file in "$HOME"/Library/Logs/DiagnosticReports/abapit*.ips; do
      if [ "$file" -nt "$marker" ]; then report="$file"; break; fi
    done
    [ -n "$report" ] && break
    sleep 1
  done
  if [ -z "$report" ]; then echo "$1: no crash report within 15 s; running it under lldb" >&2; debug_run; return 0; fi
  python3 -I - "$report" <<'PY' || true
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
body = json.loads(text.split("\n", 1)[1])
print("crash:", json.dumps(body.get("exception", {})), json.dumps(body.get("termination", {}).get("indicator", "")))
if "asi" in body:
    print("asi:", json.dumps(body["asi"])[:2000])
images = body.get("usedImages", [])
thread = body.get("threads", [{}])[body.get("faultingThread", 0)]
for i, frame in enumerate(thread.get("frames", [])[:30]):
    index = frame.get("imageIndex", -1)
    image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
    print(f"  {i:2} {image:28} {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")
PY
}

# No report (CI's runners write none): the same run again under lldb, which stops at the signal and prints the
# crashed thread's frames. Bounded like any run; its picture, if it gets that far, is dropped.
debug_run() {
  local dlog
  dlog="$(mktemp)"
  env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    ABAPIT_DEMO=1 ABAPIT_SCREEN="$section" ABAPIT_SNAPSHOT="$name-lldb.png" \
    ${selected:+ABAPIT_SELECT="$selected"} ${window:+ABAPIT_WINDOW="$window"} \
    /usr/bin/lldb --batch -o run -k "thread backtrace -c 40" -k "quit" -- "$binary" > "$dlog" 2>&1 &
  local pid=$!
  for _ in $(seq 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "$name: lldb run still going after 120 s" >&2; fi
  wait "$pid" || true
  grep -E 'stop reason|frame #|Fatal error|precondition|error:' "$dlog" || echo "$name: lldb printed no frames" >&2
  rm -f "$dlog"
}

status=0
# name:section[:selected[:window]] — section is a SidebarItem raw value (AppModels/Navigation.swift). The narrow-*
# runs open a section in the smallest window with the sidebar and any inspector dragged to their widest, where
# SwiftGamGui's narrow-window layout loop crashed AppKit (its failure-log 2026-10-10): they fail when the pane has
# too little room to spare, and on any non-zero exit. The demo org: seeded data, strict stub. `first` selects the
# shown list's first row so its inspector shows (each screen's `selectsFirstRow` hook). NavigationTests holds this
# list: every screen a run, every inspector a `first` run and a narrow one.
for spec in overview:overview devices:devices device-inspector:devices:first services:services \
            apple-mdm:apple-mdm apple-mdm-detail:apple-mdm:first people:people people-detail:people:first \
            content:content content-detail:content:first activity:activity activity-detail:activity:first \
            settings:settings narrow-overview:overview::smallest narrow-device-inspector:devices:first:smallest \
            narrow-apple-mdm-detail:apple-mdm:first:smallest narrow-people-detail:people:first:smallest \
            narrow-content-detail:content:first:smallest narrow-activity-detail:activity:first:smallest; do
  IFS=: read -r name section selected window <<< "$spec"
  file="$out/$name.png"
  rm -f "$file"
  : > "$log"
  touch "$marker"
  env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    ABAPIT_DEMO=1 ABAPIT_SCREEN="$section" ABAPIT_SNAPSHOT="$name.png" \
    ${selected:+ABAPIT_SELECT="$selected"} ${window:+ABAPIT_WINDOW="$window"} "$binary" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  hung=0
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; hung=1; echo "::error::$name: no snapshot within 60 s" >&2; status=1; fi
  code=0; wait "$pid" || code=$?
  cat "$log"
  if [ "$hung" = 0 ] && [ "$code" != 0 ]; then
    echo "::error::$name: abapit exited with status $code" >&2; status=1
    [ "$code" -gt 128 ] && crash_report "$name"
  fi
  written="$(sed -nE 's/^snapshot: (\/.*\.png)$/\1/p' "$log" | tail -1)"
  if [ -n "$written" ] && [ -s "$written" ]; then mv "$written" "$file"; echo "$name: $file"; else echo "::error::$name: no image written" >&2; status=1; fi
done
exit "$status"
