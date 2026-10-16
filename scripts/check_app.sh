#!/usr/bin/env bash
# Check a built abapit.app before anyone runs it with credentials (plan §3.9). Adapted from SwiftGamGui
# scripts/check_app.sh @ bfdb494:
# - hardened runtime on; the entitlements are EXACTLY the list for its signing (ad-hoc/CI: the App
#   Sandbox, outgoing connections, user-selected files; a team build adds its keychain access group);
#   a Release build is not debuggable (get-task-allow would let a same-user process read keys and
#   tokens out of its memory);
# - every Mach-O in the bundle signed, verifying strictly, hardened, and only in Contents/MacOS;
# - the bundle's identity: bundle ID, display name = bundle name (macOS reads any other as a rename,
#   SwiftGamGui failure-log 2026-10-10), minimum macOS 27.0;
# - no listener: the binary links no server API (plan L2).
# It checks a Release build (Debug builds keep get-task-allow and skip the hardened runtime).
# Usage: scripts/check_app.sh path/to/Release/abapit.app
set -euo pipefail
APP="${1:?usage: check_app.sh path/to/Release/abapit.app}"
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/abapit"
fail() { echo "check_app: $*" >&2; exit 1; }
# Captured, never piped into `grep -q`: it exits at the first match, and under pipefail the writer's
# SIGPIPE would read as a failure.
runtime() { local info; info="$(codesign -dv "$1" 2>&1)" || return 1; grep -qE 'flags=0x[0-9a-f]+\(([^)]*,)?runtime' <<<"$info"; }
keys() {
  local xml
  xml="$(codesign -d --entitlements - --xml "$1" 2>/dev/null)" || return 1
  plutil -convert json -o - - <<<"$xml" 2>/dev/null \
    | python3 -I -c 'import json,sys; d=sys.stdin.read().strip(); print(" ".join(sorted(json.loads(d) if d else {})))'
}

codesign --verify --deep --strict "$APP" || fail "the app or its nested code doesn't verify"
runtime "$APP" || fail "the app: hardened runtime is off"
got="$(keys "$APP")" || fail "the app's entitlements can't be read"
want="com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client"
team="$(codesign -dv "$APP" 2>&1 | sed -nE 's/^TeamIdentifier=(.*)$/\1/p')"
if [ -n "$team" ] && [ "$team" != "not set" ]; then
  want="com.apple.application-identifier com.apple.developer.team-identifier com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client keychain-access-groups"
fi
[ "$got" = "$want" ] || fail "the app's entitlements are [$got]; expected exactly [$want]"
# Every boolean entitlement must be true: a key present with false would pass the list above. (Not
# plutil -extract: it reads the dots in an entitlement's name as a key path.)
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - \
  | python3 -I -c 'import json,sys; d=json.load(sys.stdin); bad=[k for k,v in d.items() if isinstance(v,bool) and not v]; sys.exit(f"entitlements set to false: {bad}" if bad else 0)' \
  || fail "an entitlement is present but off (above); the App Sandbox must be on"

count=0
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in Mach-O*) ;; *) continue ;; esac
  case "$f" in "$APP/Contents/MacOS/"*) ;; *) fail "code outside its place: ${f#"$APP"/}" ;; esac
  codesign --verify --strict "$f" 2>/dev/null || fail "unsigned or broken code: ${f#"$APP"/}"
  runtime "$f" || fail "hardened runtime is off: ${f#"$APP"/}"
  count=$((count + 1))
done < <(find "$APP" -type f -print0)

# No listener (plan L2): the binary imports no socket-server or listener API.
symbols="$(nm -u "$BINARY" 2>/dev/null)" || fail "can't read the binary's imported symbols"
for listener in _bind _listen _accept _nw_listener_create _CFSocketCreate; do
  if grep -qxE "[[:space:]]*${listener}" <<<"$symbols"; then fail "the binary imports ${listener#_}: no listener (plan L2)"; fi
done

[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "io.github.goetchstone.swiftabapit" ] || fail "bundle identifier"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "$(basename "$APP" .app)" ] \
  || fail "the display name isn't the bundle's name, so macOS shows the file name"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "abapit" ] || fail "display name"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "27.0" ] || fail "minimum macOS"
echo "check_app: ok ($(plutil -extract CFBundleIdentifier raw -o - "$PLIST"); entitlements [$got]; $count signed Mach-O file(s))"
