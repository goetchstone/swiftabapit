#!/usr/bin/env bash
# The App Intents from outside the app, by bundle ID (Apple's AppIntentsTesting): registers a built abapit.app with Launch
# Services, then reads its intents' definitions and parameters (scripts/intents_probe.swift). CI only: it registers a build
# with Launch Services, and Siri could then pick that copy on the operator's Mac, so this refuses to run outside CI.
#
#   scripts/intents_test.sh path/to/Release/abapit.app
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: scripts/intents_test.sh path/to/abapit.app}"
[ "${GITHUB_ACTIONS:-}" = true ] || { echo "intents_test: CI only (it registers the build with Launch Services)" >&2; exit 1; }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -f -R "$app"
frameworks="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" scripts/intents_probe.swift -o "$work/probe"
"$work/probe" > "$work/log" 2>&1 &
pid=$!
for _ in $(seq 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then kill "$pid"; cat "$work/log"; echo "intents_test: no answer within 120 s" >&2; exit 1; fi
code=0; wait "$pid" || code=$?
cat "$work/log"
exit "$code"
