#!/usr/bin/env bash
# Check a built abapit.app before anyone runs it with credentials (plan §3.9). Adapted from SwiftGamGui
# scripts/check_app.sh @ bfdb494, and hardened by Phase 0's review (failure-log 2026-10-16):
# - the entitlements are EXACTLY these, keys and values (a key present with 0, "NO" or false is not "on"):
#   ad-hoc/CI: the App Sandbox, outgoing connections, user-selected files, each `true`; a team build adds
#   exactly its own keychain access group, application identifier and team identifier;
# - hardened runtime on; a Release build is not debuggable (get-task-allow would let a same-user process
#   read keys and tokens out of its memory);
# - exactly one Mach-O in the bundle: Contents/MacOS/abapit, signed and verifying strictly;
# - no listener: the binary imports no socket-server or listener API (plan L2), and no ATS exception;
# - no debug-only code: the spike and snapshot switches are absent from a Release binary;
# - the bundle's identity: bundle ID, display name = bundle name (macOS reads any other as a rename,
#   SwiftGamGui failure-log 2026-10-10), minimum macOS 27.0.
# It checks a Release build. Usage: scripts/check_app.sh path/to/Release/abapit.app
set -euo pipefail
APP="${1:?usage: check_app.sh path/to/Release/abapit.app}"
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/abapit"
BUNDLE_ID="io.github.goetchstone.swiftabapit"
fail() { echo "check_app: $*" >&2; exit 1; }
# Captured, never piped into `grep -q`: it exits at the first match, and under pipefail the writer's
# SIGPIPE would read as a failure.
runtime() { local info; info="$(codesign -dv "$1" 2>&1)" || return 1; grep -qE 'flags=0x[0-9a-f]+\(([^)]*,)?runtime' <<<"$info"; }

codesign --verify --deep --strict "$APP" || fail "the app or its nested code doesn't verify"
runtime "$APP" || fail "the app: hardened runtime is off"

# Exactly one Mach-O, where it belongs (a helper beside it would carry its own entitlements and imports).
machos=()
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in Mach-O*) machos+=("${f#"$APP"/}") ;; esac
done < <(find "$APP" -type f -print0)
[ "${#machos[@]}" = 1 ] && [ "${machos[0]}" = "Contents/MacOS/abapit" ] || fail "the bundle's code is [${machos[*]}]; only Contents/MacOS/abapit may be code"
[ ! -L "$BINARY" ] || fail "the executable is a link"

# The entitlements, compared whole: names and values.
team="$(codesign -dv "$APP" 2>&1 | sed -nE 's/^TeamIdentifier=(.*)$/\1/p')"
[ "$team" = "not set" ] && team=""
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)" \
  || fail "the app's entitlements can't be read"
checker='
import json, re, sys
team, bundle = sys.argv[1], sys.argv[2]
got = json.load(sys.stdin)
want = {"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
        "com.apple.security.files.user-selected.read-write": True}
if team:
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        sys.exit(f"team identifier {team!r} is not one")
    want.update({"keychain-access-groups": [f"{team}.{bundle}"], "com.apple.application-identifier": f"{team}.{bundle}",
                 "com.apple.developer.team-identifier": team})
# bool True only: 1, "YES" or "true" are not the boolean the sandbox reads.
same = got.keys() == want.keys() and all(type(got[k]) is type(want[k]) and got[k] == want[k] for k in want)
if not same:
    sys.exit(f"entitlements are {json.dumps(got, sort_keys=True)}; expected exactly {json.dumps(want, sort_keys=True)}")
'
python3 -I -c "$checker" "$team" "$BUNDLE_ID" <<<"$entitlements" || fail "entitlements (above)"

# No listener (plan L2): no server-socket, listener or service-publishing symbol is imported.
symbols="$(nm -u "$BINARY" 2>/dev/null)" || fail "can't read the binary's imported symbols"
if hits="$(grep -E '^_(bind|listen|accept|accept4)$|nw_listener|NWListener|NSSocketPort|SocketPort|CFSocketCreate|CFSocketSetAddress|NSNetService|DNSServiceRegister|GCDWebServer|HTTPServer' <<<"$symbols")"; then
  fail "the binary imports listener APIs: $(tr '\n' ' ' <<<"$hits")"
fi
# No App Transport Security exception.
if plutil -extract NSAppTransportSecurity raw -o - "$PLIST" >/dev/null 2>&1; then fail "the Info.plist has an App Transport Security exception"; fi
# No debug-only code in Release: the spike and snapshot switches, and TestSupport's strict stubs and demo fleet
# (compiled out under #if DEBUG; linking alone would keep them, through Swift's conformance records).
if strings -a "$BINARY" | grep -qE 'ABAPIT_(SPIKE|SNAPSHOT|DEMO)|stub-token-|Example Business \(demo\)'; then fail "debug-only code or strings are in the binary"; fi
if nm "$BINARY" 2>/dev/null | grep -qE 'TestSupport|AppleStub|DemoFleet|DemoOrg|MemoryStore'; then fail "test or demo code is linked into the binary"; fi

[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "$BUNDLE_ID" ] || fail "bundle identifier"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "$(basename "$APP" .app)" ] \
  || fail "the display name isn't the bundle's name, so macOS shows the file name"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "abapit" ] || fail "display name"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "27.0" ] || fail "minimum macOS"
echo "check_app: ok ($BUNDLE_ID; ${team:-ad-hoc}; exact entitlements; one Mach-O; no listener, ATS exception or debug switch)"
