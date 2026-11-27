#!/usr/bin/env bash
# Check a built abapit.app before anyone runs it with credentials (plan §3.9). Adapted from SwiftGamGui
# scripts/check_app.sh @ bfdb494, and hardened by Phase 0's review (failure-log 2026-10-16):
# - the entitlements are EXACTLY these, keys and values (a key present with 0, "NO" or false is not "on"):
#   ad-hoc/CI: the App Sandbox, outgoing connections, user-selected files, each `true`; a team build adds
#   exactly its own keychain access group, application identifier and team identifier;
# - hardened runtime on; a Release build is not debuggable (get-task-allow would let a same-user process
#   read keys and tokens out of its memory);
# - exactly one Mach-O in the bundle: Contents/MacOS/abapit, signed and verifying strictly;
# - no listener: the binary imports no socket-server or listener API (plan L2), and no ATS exception; and no
#   second door: it starts no other program (a child inherits the sandbox's network entitlement);
# - no debug-only code: a Release binary reads no environment variable, launch argument or user default at all
#   (so no debug switch, whatever its name: UserDefaults reads `-key value` launch arguments itself), and carries
#   none of TestSupport's stubs or demo and no Vault MemoryStore, checked on the binary as built and on a copy
#   stripped as an archive build strips it (Phase 1b's review M1 and its gates verifier round 1; Phase 7a's H1);
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

# No App Transport Security exception.
if plutil -extract NSAppTransportSecurity raw -o - "$PLIST" >/dev/null 2>&1; then fail "the Info.plist has an App Transport Security exception"; fi

# What the code must not do or carry, checked twice: on a copy stripped the way an archive build strips it
# (DEPLOYMENT_POSTPROCESSING=YES runs `strip -D`: no symbol table), then on the binary as built. Phase 1b's review
# linked the stub into a stripped build and this gate passed it, because only `nm` looked for the stub. A hit
# only the second pass finds lives in the symbol table alone, which an archive drops.
# Each tool's output is captured before it is searched: under pipefail, `tool | grep -q` reads a match as no
# match once the output outgrows the pipe (grep exits, the writer dies of SIGPIPE). `nm | grep -q` missed the
# linked stub that way, and MemoryStore in every Release build (failure-log 2026-10-16, "the gate looked for what
# it could not see"; Phase 7a's review H1). SourceScanTests' GateScriptTests refuse that pipe in scripts/.
copy="$(mktemp -d)"
trap 'rm -rf "$copy"' EXIT
xcrun strip -D -o "$copy/abapit" "$BINARY" 2>/dev/null || fail "can't make a stripped copy of the binary"
DEBUG_ONLY='ABAPIT_[A-Z_]*|stub-token-|Example Business \(demo\)|TestSupport|AppleStub|MosyleStub|DemoFleet|DemoOrg|MemoryStore'
release_code() {  # binary, what to call it, what a hit means beyond itself
  local bin="$1" name="$2" hint="$3" imports selectors text names hits
  imports="$(nm -u "$bin" 2>/dev/null)" || fail "can't read $name's imported symbols"
  selectors="$(otool -v -s __TEXT __objc_methname "$bin" 2>/dev/null)" || fail "can't read $name's selector names"
  text="$(strings -a "$bin")" || fail "can't read $name's strings"
  names="$(nm "$bin" 2>/dev/null)" || fail "can't read $name's symbols"
  # No listener (plan L2): no server-socket, listener or service-publishing symbol is imported.
  if hits="$(grep -E '^_(bind|listen|accept|accept4)$|nw_listener|NWListener|NSSocketPort|SocketPort|CFSocketCreate|CFSocketSetAddress|NSNetService|DNSServiceRegister|GCDWebServer|HTTPServer' <<<"$imports")"; then
    fail "$name imports listener APIs: $(tr '\n' ' ' <<<"$hits")$hint"
  fi
  # No debug switch: Release reads no environment variable, launch argument or user default. The switch names can't
  # be looked for: Swift keeps a string literal of 15 bytes or fewer inside the instructions, so `strings` never
  # shows ABAPIT_DEMO (11 bytes); SourceScanTests' DebugOnlyTests hold the names in the source. The read can be:
  # ProcessInfo's `environment` and `arguments` selectors, or either through key-value coding (`valueForKey:`, whose
  # key is an inline literal too); getenv and its kin; Swift's CommandLine; and UserDefaults, which reads a
  # `-key value` launch argument itself: its class, `standardUserDefaults`, SwiftUI's AppStorage, CFPreferences.
  # `UserDefaults.standard.bool(forKey: "ABAPIT" + "_DEMO")` passed the gate and the name scan before these. Swift
  # reads Darwin's `environ` through the overlay's getter (`_$s6Darwin7environ…vg`, never `_environ`), and sysctl's
  # KERN_PROCARGS2 returns the process's own arguments and environment: both passed (gates verifier round 2).
  if hits="$(grep -E '[[:space:]](environment|arguments|standardUserDefaults|valueForKey:|valueForKeyPath:)$' <<<"$selectors")"; then
    fail "$name reads its environment, arguments or defaults (a debug switch outside #if DEBUG?): $(tr -s ' \n' ' ' <<<"$hits")$hint"
  fi
  if hits="$(grep -E '^_(getenv|secure_getenv|environ|_NSGetEnviron|_NSGetArgv|_NSGetArgc|sysctl|sysctlbyname|sysctlnametomib)$|6Darwin7environ|^_proc_pid|11CommandLineO|^_OBJC_CLASS_\$_NSUserDefaults|AppStorage|^_CFPreferences' <<<"$imports")"; then
    fail "$name reads its environment, arguments or defaults: $(tr '\n' ' ' <<<"$hits")$hint"
  fi
  # No second door: a child process (Process is NSTask; a script runs a shell) inherits the network entitlement and
  # fetches past HTTPCore's host allowlist (RouteTests.nothingStartsAProgram holds the source).
  if hits="$(grep -E '^_(posix_spawnp?|execv[ep]?)$|^_OBJC_CLASS_\$_(NSTask|NSAppleScript|OSAScript|NSUser(Unix|AppleScript|Automator)?Task)$' <<<"$imports")"; then
    fail "$name can start another program: $(tr '\n' ' ' <<<"$hits")$hint"
  fi
  # No other way to a host (invariant 4): the transport is URLSession's. Nothing imports a BSD socket or the resolver,
  # Foundation's Host or stream pair, SwiftUI's AsyncImage, a web view, or what hands a URL or data to another app
  # (NSWorkspace, LSOpen…, NSSharingService). A Release build imports none of these (measured 2026-11-18 on two builds, 1,448
  # imports each); a review's probes imported each and this gate printed ok (failure-log 2026-11-18). It reads the
  # binary, so it sees code no source scan read. RouteTests.nothingReachesAHostAnotherWay holds the source.
  if hits="$(grep -E '^_(socket|connect|connectx|getaddrinfo|gethostbyname2?|gethostbyaddr)$|NSHost|CFHost|NSStream|NSInputStream|NSOutputStream|CFStreamCreatePairWith|AsyncImage|NSWorkspace|^_LSOpen|NSSharingService|WKWebView|_WebKit_SwiftUI' <<<"$imports")"; then
    fail "$name imports another way to a host: $(tr '\n' ' ' <<<"$hits")$hint"
  fi
  # No debug-only code: TestSupport's strict stubs and demo, and Vault's MemoryStore, all compiled out under
  # #if DEBUG (linking alone would keep them, through Swift's conformance records). MemoryStore keeps a key in
  # memory; it was public and in every Release build (101 symbols), and the piped `nm | grep -q` never said so
  # (Phase 7a's review H1). A strip keeps their class names (_TtC11TestSupport9AppleStub, MemoryStore's) and
  # #filePath paths (.../Sources/TestSupport/...), which `TestSupport` matches; a longer ABAPIT_ string (a message
  # naming a switch); the stub's token prefix and the demo org's name. `strings -a` reads every section but not the
  # symbol table, so the same needles are looked for in `nm` too: a TestSupport free function linked into Release
  # shows nowhere else (mutant FN, in the gates repair after Phase 1b's verifier round 1).
  if hits="$(grep -oE "$DEBUG_ONLY" <<<"$text" | sort -u)"; then
    fail "debug-only code or strings are in $name: $(tr '\n' ' ' <<<"$hits")$hint"
  fi
  if hits="$(grep -oE "$DEBUG_ONLY" <<<"$names" | sort -u)"; then
    fail "test or demo code is linked into $name: $(tr '\n' ' ' <<<"$hits")$hint"
  fi
}
release_code "$copy/abapit" "the stripped binary" ""
release_code "$BINARY" "the binary" " (only its symbol table shows this: an archive build strips it and would ship the code unseen)"

# App Intents (Phase 9, adapted from SwiftGamGui scripts/check_app.sh @ e8560f2): the built metadata is what Siri and Shortcuts
# read, and Xcode checks its rules only while it builds, so it is read here.
# - exactly these intents (Get report CSV since S9.10: Shortcuts only, no phrase, a report's CSV as a file; Ask since S9.7: its one parameter is the question as a string, and it has a phrase), each read-only (`App/Intents/`; SourceScanTests' `noIntentReachesAWrite` holds the source): a new
#   intent is a reviewed change to this list. Each runs in the background only (supportedModes 1: never opens a window) and asks
#   for the Mac's own authentication first (authenticationPolicy 2, requiresLocalDeviceAuthentication, set in the code);
# - every phrase names the app, and every phrase is in the phrase catalog the build ships (`en.lproj/AppShortcuts.strings`, from
#   App/AppShortcuts.xcstrings): without it Siri never matched a phrase by voice (SwiftGamGui failure-log 2026-10-10);
# - no app entity at all, so none is indexed for Spotlight (the operator, 2026-11-24, Q2 "Out for now": no device serial or name in
#   the system index), and the binary imports no Spotlight index.
INTENTS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
PHRASES="$APP/Contents/Resources/en.lproj/AppShortcuts.strings"
[ -f "$INTENTS" ] && [ ! -L "$INTENTS" ] || fail "no App Intents metadata"
# Every App Intents metadata file in the bundle, wherever it is, is held to the same rules: one elsewhere (a nested bundle's) would
# declare intents this check never read (the review of PR 52).
metadata=()
while IFS= read -r -d '' f; do metadata+=("$f"); done < <(find "$APP" -name extract.actionsdata -print0)
[ "${#metadata[@]}" -ge 1 ] || fail "no App Intents metadata"
[ -f "$PHRASES" ] && [ ! -L "$PHRASES" ] || fail "no App Shortcuts phrase catalog (App/AppShortcuts.xcstrings)"
catalog="$(plutil -convert json -o - "$PHRASES" 2>/dev/null)" || fail "the phrase catalog can't be read"
intents_checker='
import json, sys
actions = {"RunReportIntent", "NeedsAttentionIntent", "LookUpSerialIntent", "OutOfWarrantyIntent", "CoverageEndingIntent",
           "FleetAgeIntent", "ActivationLockIntent", "MigrationIntent", "ServiceHealthIntent", "AskIntent", "GetReportCSVIntent"}
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
d = json.loads(text)
catalog = json.load(sys.stdin)
got = d.get("actions", {})
if set(got) != actions:
    sys.exit(f"the intents are {sorted(got)}; expected exactly {sorted(actions)}")
for name, action in sorted(got.items()):
    modes, policy = action.get("supportedModes"), action.get("authenticationPolicy")
    if type(modes) is not int or modes != 1:
        sys.exit(f"{name} runs in modes {modes!r}, not the background alone (1)")
    if type(policy) is not int or policy != 2 or action.get("isAuthPolExplicit") is not True:
        sys.exit(f"{name} asks authentication policy {policy!r}, not requiresLocalDeviceAuthentication (2) set in the code")
    if action.get("openAppWhenRun") is not False:
        sys.exit(f"{name} opens the app when run")
phrases = [p.get("key", "") if isinstance(p, dict) else str(p)
           for s in d.get("autoShortcuts", []) for p in s.get("phraseTemplates", [])]
if not phrases:
    sys.exit("no Siri phrases")
unnamed = [p for p in phrases if "${applicationName}" not in p]
if unnamed:
    sys.exit(f"phrases without the app name: {unnamed}")
missing = [p for p in phrases if catalog.get(p) != p]
if missing:
    sys.exit(f"phrases not in the built phrase catalog: {missing}")
shortcuts = {s.get("actionIdentifier") for s in d.get("autoShortcuts", [])}
if not shortcuts <= actions or not {"NeedsAttentionIntent", "LookUpSerialIntent", "OutOfWarrantyIntent", "AskIntent"} <= shortcuts:
    sys.exit(f"the App Shortcuts are for {sorted(map(str, shortcuts))}")
# Ask takes one thing, the question as plain text: no entity, no file, nothing optional that could carry another input.
ask = [(p.get("name"), p.get("isOptional"), p.get("valueType")) for p in got["AskIntent"].get("parameters", [])]
if ask != [("question", False, {"primitive": {"wrapper": {"typeIdentifier": 0}}})]:
    sys.exit(f"AskIntent takes {ask}, not one required string named question")
# Get report CSV is for Shortcuts only (it returns a file, which a spoken request has nowhere to put): it is in no App Shortcut, so no
# phrase reaches it, and it takes the three parameters of RunReportIntent, a report, a group and a number, and nothing else.
if "GetReportCSVIntent" in shortcuts:
    sys.exit("GetReportCSVIntent is in an App Shortcut: it has no Siri phrase")
def params(name):
    return [(p.get("name"), p.get("isOptional"), json.dumps(p.get("valueType"), sort_keys=True)) for p in got[name].get("parameters", [])]
csv_params, run_params = params("GetReportCSVIntent"), params("RunReportIntent")
if csv_params != run_params or [n for n, _, _ in csv_params] != ["report", "group", "number"]:
    sys.exit(f"GetReportCSVIntent takes {csv_params}, not the report, group and number of RunReportIntent: {run_params}")
if d.get("entities") or d.get("assistantEntities") or d.get("queries") or "Indexed" in text or "indexingKey" in text:
    sys.exit("the metadata holds an app entity, a query or an indexed type (Spotlight is out: the operator, 2026-11-24, Q2)")
'
for f in "${metadata[@]}"; do
  [ ! -L "$f" ] || fail "${f#"$APP"/} is a link"
  python3 -I -c "$intents_checker" "$f" <<<"$catalog" || fail "App Intents metadata in ${f#"$APP"/} (above)"
done
imports="$(nm -u "$BINARY" 2>/dev/null)" || fail "can't read the binary's imported symbols"
if hits="$(grep -E 'CSSearchableIndex|CSSearchableItem|IndexedEntity' <<<"$imports")"; then
  fail "the binary imports a Spotlight index (Spotlight is out: the operator, 2026-11-24, Q2): $(tr '\n' ' ' <<<"$hits")"
fi

[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "$BUNDLE_ID" ] || fail "bundle identifier"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "$(basename "$APP" .app)" ] \
  || fail "the display name isn't the bundle's name, so macOS shows the file name"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "abapit" ] || fail "display name"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "27.0" ] || fail "minimum macOS"
echo "check_app: ok ($BUNDLE_ID; ${team:-ad-hoc}; exact entitlements; one Mach-O; no listener, child process, ATS exception, environment, argument or defaults read, or host routes, or debug code, stripped or not; read-only background intents, every phrase named and in the catalog, no Spotlight index)"
