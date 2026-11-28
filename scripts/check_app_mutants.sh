#!/usr/bin/env bash
# The standing mutants of scripts/check_app.sh: the Release gate must refuse every one below, and say why.
# A check that was never seen to fail can't hold (failure-log 2026-10-16, "the gate checked names, not values" and
# "the gate looked for what it could not see"). Each mutant is a fresh copy of a Release app that passes, changed
# in one way, signed ad-hoc and handed to the gate. A mutant counts as refused only when the gate exits non-zero
# AND prints the reason named here, so a refusal for another reason is a failure of this self-test.
# Nothing here runs the app or a mutant binary: the binaries are compiled, copied in and signed, never started.
# The copy keeps the name abapit.app, because the gate checks the bundle's name.
# Usage: scripts/check_app_mutants.sh path/to/Release/abapit.app
#   CHECK_APP_GATE=path/to/another/check_app.sh overrides the gate (to show this self-test fails on a weakened one).
set -uo pipefail
APP="${1:?usage: check_app_mutants.sh path/to/Release/abapit.app (one that passes scripts/check_app.sh)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="${CHECK_APP_GATE:-$HERE/check_app.sh}"
ENT="$HERE/../Config/abapit.entitlements"
[ -d "$APP" ] || { echo "check_app_mutants: no app at $APP" >&2; exit 1; }
[ -f "$GATE" ] || { echo "check_app_mutants: no gate at $GATE" >&2; exit 1; }
[ -f "$ENT" ] || { echo "check_app_mutants: no entitlements at $ENT" >&2; exit 1; }
S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
refused=0
missed=0

stop() { echo "check_app_mutants: $*" >&2; exit 1; }
fresh() { rm -rf "$S/abapit.app"; cp -R "$APP" "$S/abapit.app" || stop "can't copy the app"; }
# Sign the copy ad-hoc with the hardened runtime and the entitlements file given.
sign() { codesign --force --sign - --options runtime --entitlements "$1" "$S/abapit.app" >/dev/null 2>&1 || stop "can't sign the mutant"; }
# The repo's entitlements with one key set to a JSON value, written to $S/e.plist.
entitlements_with() {
  python3 -I -c '
import json, plistlib, sys
with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
entitlements[sys.argv[2]] = json.loads(sys.argv[3])
with open(sys.argv[4], "wb") as target:
    plistlib.dump(entitlements, target)' "$ENT" "$1" "$2" "$S/e.plist" || stop "can't write the mutant entitlements"
}
# A program compiled to $S/<name>, never run. C from a .c source, Swift from a .swift source.
build() {
  local name="$1" source="$2"
  case "$source" in
    *.c) clang -o "$S/$name" "$source" >/dev/null 2>&1 || stop "can't compile $source" ;;
    *) swiftc -O "$source" -o "$S/$name" >/dev/null 2>&1 || stop "can't compile $source" ;;
  esac
}
# The copy with its executable replaced by the program $S/<name>.
with_binary() { fresh; cp "$S/$1" "$S/abapit.app/Contents/MacOS/abapit" || stop "can't replace the executable"; sign "$ENT"; }
# Run the gate on the mutant: refused means a non-zero exit and the named reason in its output.
expect() {
  local label="$1" reason="$2" out status last
  out="$("$GATE" "$S/abapit.app" 2>&1)"
  status=$?
  last="$(tail -n 1 <<<"$out")"
  if [ "$status" != 0 ] && grep -F -e "$reason" <<<"$out" >/dev/null; then
    refused=$((refused + 1))
    echo "refused: $label :: ${last:0:140}"
  else
    missed=$((missed + 1))
    echo "NOT REFUSED AS EXPECTED: $label (exit $status, wanted \"$reason\") :: ${last:0:200}"
  fi
}

# Control: the unchanged app passes, and so does an unchanged copy signed the way every mutant is signed.
out="$("$GATE" "$APP" 2>&1)" || { echo "$out" >&2; stop "the unchanged app does not pass the gate"; }
fresh; sign "$ENT"
out="$("$GATE" "$S/abapit.app" 2>&1)" || { echo "$out" >&2; stop "an unchanged, re-signed copy does not pass the gate"; }
echo "control: the unchanged app and its re-signed copy pass"

# Entitlements: the sandbox key present with a value that is not the boolean true; an extra key.
for value in 0 '"NO"' 1 '"true"'; do
  fresh; entitlements_with com.apple.security.app-sandbox "$value"; sign "$S/e.plist"
  expect "sandbox entitlement = $value" "entitlements"
done
fresh; entitlements_with com.apple.security.network.server true; sign "$S/e.plist"
expect "an added network.server entitlement" "entitlements"
fresh; entitlements_with com.apple.security.get-task-allow true; sign "$S/e.plist"
expect "an added get-task-allow entitlement" "entitlements"

# Hardened runtime off.
fresh; codesign --force --sign - --entitlements "$ENT" "$S/abapit.app" >/dev/null 2>&1 || stop "can't sign the mutant"
expect "signed without the hardened runtime" "hardened runtime is off"

# A second executable beside the app's own.
printf 'int main(void) { return 0; }\n' > "$S/helper.c"
build helper "$S/helper.c"
fresh; cp "$S/helper" "$S/abapit.app/Contents/MacOS/helper" || stop "can't add the helper"
codesign --force --sign - --options runtime "$S/abapit.app/Contents/MacOS/helper" >/dev/null 2>&1 || stop "can't sign the helper"
sign "$ENT"
expect "a second Mach-O in Contents/MacOS" "only Contents/MacOS/abapit may be code"

# A listener: Network.framework's, and the C socket calls.
printf 'import Network\nlet listener = try! NWListener(using: .tcp, on: 8080)\nprint(listener)\n' > "$S/nwlistener.swift"
build nwlistener "$S/nwlistener.swift"
with_binary nwlistener
expect "an executable that uses NWListener" "listener APIs"
printf '#include <sys/socket.h>\nint main(void) { int s = socket(2, 1, 0); bind(s, 0, 0); listen(s, 1); accept(s, 0, 0); return 0; }\n' > "$S/clisten.c"
build clisten "$S/clisten.c"
with_binary clisten
expect "an executable that calls bind, listen and accept" "listener APIs"

# A debug switch's read: the environment, the arguments, the defaults.
printf '#include <stdlib.h>\n#include <stdio.h>\nint main(void) { const char *v = getenv("X"); puts(v ? v : ""); return 0; }\n' > "$S/cgetenv.c"
build cgetenv "$S/cgetenv.c"
with_binary cgetenv
expect "an executable that calls getenv" "reads its environment, arguments or defaults"
printf 'import Foundation\nprint(ProcessInfo.processInfo.environment.count)\n' > "$S/swiftenv.swift"
build swiftenv "$S/swiftenv.swift"
with_binary swiftenv
expect "an executable that reads ProcessInfo's environment" "reads its environment, arguments or defaults"
printf 'print(CommandLine.arguments.count)\n' > "$S/swiftargs.swift"
build swiftargs "$S/swiftargs.swift"
with_binary swiftargs
expect "an executable that reads CommandLine.arguments" "reads its environment, arguments or defaults"
printf 'import Foundation\nprint(UserDefaults.standard.bool(forKey: "x"))\n' > "$S/swiftdefaults.swift"
build swiftdefaults "$S/swiftdefaults.swift"
with_binary swiftdefaults
expect "an executable that reads UserDefaults" "reads its environment, arguments or defaults"

# A second door: starting another program.
printf '#include <spawn.h>\nint main(void) { pid_t p; char *a[] = { "x", 0 }; return posix_spawn(&p, "/usr/bin/true", 0, 0, a, 0); }\n' > "$S/cspawn.c"
build cspawn "$S/cspawn.c"
with_binary cspawn
expect "an executable that calls posix_spawn" "can start another program"

# Debug-only strings in the binary (a C literal is kept whole, so `strings` shows it).
printf '#include <stdio.h>\nint main(void) { puts("ABAPIT_DEMO_IS_SET_IN_RELEASE"); return 0; }\n' > "$S/cswitch.c"
build cswitch "$S/cswitch.c"
with_binary cswitch
expect "an executable that carries an ABAPIT_ string" "debug-only code or strings"

# Debug-only code that the symbol table alone shows (a function's name is in no section, so `strings` never
# prints it): what an archive build strips and would ship unseen. This is the check a pipe once blinded
# (failure-log 2026-10-16, "the gate looked for what it could not see").
printf '__attribute__((used)) int DemoFleetLinkedIntoRelease(void) { return 1; }\nint main(void) { return 0; }\n' > "$S/csymbol.c"
build csymbol "$S/csymbol.c"
with_binary csymbol
expect "an executable whose symbol table alone names debug-only code" "test or demo code is linked into"

# Another way to a host than URLSession (invariant 4): the gate's host-route check reads the imports, so each family it
# names gets a binary that imports only that family. The reason names the import the gate must print.
printf '#include <sys/socket.h>\n#include <netdb.h>\nint main(void) { struct addrinfo *r = 0; getaddrinfo("x", "443", 0, &r); int s = socket(2, 1, 0); return connect(s, 0, 0); }\n' > "$S/cconnect.c"
build cconnect "$S/cconnect.c"
with_binary cconnect
expect "an executable that calls socket, connect and getaddrinfo" "another way to a host: _connect"
printf '#include <CoreServices/CoreServices.h>\nint main(void) { return (int)LSOpenCFURLRef(0, 0); }\n' > "$S/clsopen.c"
clang -framework CoreServices -o "$S/clsopen" "$S/clsopen.c" >/dev/null 2>&1 || stop "can't compile $S/clsopen.c"
with_binary clsopen
expect "an executable that calls LSOpenCFURLRef" "another way to a host: _LSOpenCFURLRef"
printf 'import Foundation\nlet host = Host(name: "x")\nprint(host.addresses)\n' > "$S/swifthost.swift"
build swifthost "$S/swifthost.swift"
with_binary swifthost
expect "an executable that uses Foundation's Host" "another way to a host: _OBJC_CLASS_\$_NSHost"
printf 'import AppKit\nprint(NSWorkspace.shared)\n' > "$S/swiftworkspace.swift"
build swiftworkspace "$S/swiftworkspace.swift"
with_binary swiftworkspace
expect "an executable that uses NSWorkspace" "another way to a host: _OBJC_CLASS_\$_NSWorkspace"
printf 'import WebKit\nprint(WKWebView())\n' > "$S/swiftwebkit.swift"
build swiftwebkit "$S/swiftwebkit.swift"
with_binary swiftwebkit
expect "an executable that uses WKWebView" "another way to a host: _OBJC_CLASS_\$_WKWebView"
printf 'import SwiftUI\nimport WebKit\nstruct Page: View { var body: some View { WebView(url: URL(string: "https://x.invalid")) } }\nprint(Page.self)\n' > "$S/swiftwebview.swift"
build swiftwebview "$S/swiftwebview.swift"
with_binary swiftwebview
expect "an executable that uses SwiftUI's WebView" "_WebKit_SwiftUI"

# An App Transport Security exception.
fresh; plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads":true}' "$S/abapit.app/Contents/Info.plist" || stop "can't edit the mutant's Info.plist"
sign "$ENT"
expect "an App Transport Security exception" "App Transport Security"

echo "check_app_mutants: $refused refused as expected, $missed not"
[ "$missed" = 0 ] || exit 1
[ "$refused" = 24 ] || { echo "check_app_mutants: expected 24 mutants, ran $refused" >&2; exit 1; }
