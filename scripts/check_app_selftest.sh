#!/usr/bin/env bash
# The Release gate's test of its own Info.plist and bundle-folder checks (failure-log 2026-11-18, "the gate read the
# entitlements, not the Info.plist"). A copy of a Release app that passes the gate gets one inbound door (a URL
# scheme, a document type, a Service, AppleScript, an activity type, a launch environment, a login-item, XPC or
# extension folder, a nested bundle, a scripting definition, InfoPlist.strings), is signed ad hoc again, and must be refused by scripts/check_app.sh with the door named.
# Xcode builds nothing here and nothing is run: a copy is changed, signed and read. The copy keeps the name
# abapit.app (the gate checks the bundle's name) and sits in a temporary folder that is removed on exit.
# Usage: scripts/check_app_selftest.sh path/to/Release/abapit.app
set -euo pipefail
[ -d "${1:-}" ] || { echo "usage: check_app_selftest.sh path/to/Release/abapit.app" >&2; exit 2; }
APP="$(cd "$1" && pwd)"
cd "$(dirname "$0")/.."
GATE="scripts/check_app.sh"
ENTITLEMENTS="Config/abapit.entitlements"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
count=0
"$GATE" "$APP" >/dev/null || { echo "check_app_selftest: the app given doesn't pass the gate, so its copies say nothing" >&2; exit 1; }

# An empty folder door (`folder`) reaches the gate's named check as it is; one with files in it would also fail
# codesign's strict check, so the `tree` doors below hold a file, are signed again (a nested bundle first, as codesign
# wants it) and still must be refused by the named check, never by codesign.
# name, the text the gate must print, then `folder <name under Contents>`, `tree <nested bundle under Contents:its door
# key, or -> [<file under Contents>=<content>]...`, or PlistBuddy commands for the Info.plist.
refused() {
  local name="$1" says="$2" out status=0
  shift 2
  rm -rf "$work/abapit.app"
  cp -R "$APP" "$work/abapit.app"
  if [ "$1" = folder ]; then
    mkdir -p "$work/abapit.app/Contents/$2"
  elif [ "$1" = tree ]; then
    local nested="$2" spec file
    shift 2
    for spec in "$@"; do
      if [[ "$spec" == *"=>"* ]]; then  # path=>target: a symlink
        file="$work/abapit.app/Contents/${spec%%=>*}"
        mkdir -p "$(dirname "$file")"
        ln -s "${spec#*=>}" "$file"
        continue
      fi
      file="$work/abapit.app/Contents/${spec%%=*}"
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "${spec#*=}" > "$file"
    done
    # A nested bundle gets an Info.plist (written by plutil from the door's keys) and a shell executable.
    if [ "$nested" != - ]; then
      local dir="$work/abapit.app/Contents/${nested%%:*}" key="${nested#*:}"
      mkdir -p "$dir/Contents/MacOS"
      printf '#!/bin/sh\nexit 0\n' > "$dir/Contents/MacOS/H"
      chmod +x "$dir/Contents/MacOS/H"
      printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>H</string><key>CFBundleIdentifier</key><string>selftest.h</string><key>%s</key><array><dict/></array></dict></plist>\n' "$key" > "$dir/Contents/Info.plist"
      codesign --force --sign - "$dir" 2>/dev/null || { echo "check_app_selftest: can't sign the nested bundle for: $name" >&2; exit 1; }
    fi
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$work/abapit.app" 2>/dev/null \
      || { echo "check_app_selftest: can't sign the copy for: $name" >&2; exit 1; }
  else
    local commands=() command
    for command in "$@"; do commands+=(-c "$command"); done
    /usr/libexec/PlistBuddy "${commands[@]}" "$work/abapit.app/Contents/Info.plist" >/dev/null \
      || { echo "check_app_selftest: can't change the copy's Info.plist for: $name" >&2; exit 1; }
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$work/abapit.app" 2>/dev/null \
      || { echo "check_app_selftest: can't sign the copy for: $name" >&2; exit 1; }
  fi
  out="$("$GATE" "$work/abapit.app" 2>&1)" || status=$?
  count=$((count + 1))
  if [ "$status" = 1 ] && grep -F -e "$says" <<<"$out" >/dev/null; then
    echo "refused: $name"
  else
    failed=1
    echo "NOT REFUSED: $name (the gate exited $status and said: $out)" >&2
  fi
}

refused "a URL scheme" "CFBundleURLTypes" 'Add :CFBundleURLTypes array' 'Add :CFBundleURLTypes:0 dict' \
  'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string abapit-selftest'
refused "a document type" "CFBundleDocumentTypes" 'Add :CFBundleDocumentTypes array' 'Add :CFBundleDocumentTypes:0 dict' \
  'Add :CFBundleDocumentTypes:0:CFBundleTypeName string selftest' 'Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer'
refused "a Service" "NSServices" 'Add :NSServices array' 'Add :NSServices:0 dict' 'Add :NSServices:0:NSMessage string selftest'
refused "AppleScript" "NSAppleScriptEnabled" 'Add :NSAppleScriptEnabled bool true'
refused "an activity type" "NSUserActivityTypes" 'Add :NSUserActivityTypes array' 'Add :NSUserActivityTypes:0 string selftest'
refused "a launch environment" "LSEnvironment" 'Add :LSEnvironment dict' 'Add :LSEnvironment:SELFTEST string 1'
refused "a value JSON can't hold" "can't be read as JSON" 'Add :SelfTestDate date "Sun Nov 01 00:00:00 GMT 2026"'
refused "a toolchain stamp that is a dict" "toolchain stamp that is not a string" 'Delete :DTXcode' 'Add :DTXcode dict'
refused "a DT key the stamps do not name, holding a dict" "keys this app does not ship" 'Add :DTWhatever dict'
refused "a login-item folder" "Contents/Library" folder Library
refused "an XPC service folder" "Contents/XPCServices" folder XPCServices
refused "an extension folder" "Contents/PlugIns" folder PlugIns

refused "a nested app in a folder of its own" "Contents holds Helpers" tree Helpers/H.app:CFBundleURLTypes
refused "a nested app in Resources" "Contents/Resources holds an Info.plist or a nested bundle" tree Resources/H.app:NSServices
refused "a file in a folder the build never writes" "Contents holds SharedSupport" tree - SharedSupport/x=x
refused "an extension in Resources" "Contents/Resources holds an Info.plist or a nested bundle" tree - Resources/E.appex=x
refused "an extension in a folder of its own" "Contents holds Extensions" tree - Extensions/E.appex=x
refused "a scripting definition" "Contents/Resources holds a scripting definition" tree - Resources/abapit.sdef=x
refused "a localized InfoPlist.strings" "Contents/Resources holds an InfoPlist.* file" tree - Resources/en.lproj/InfoPlist.strings=x
refused "a nested app in MacOS" "Contents/MacOS holds more than abapit" tree MacOS/H.app:CFBundleURLTypes
refused "a symlink in Resources" "Contents/Resources holds a symlink" tree - "Resources/apps=>/System/Applications"
refused "a localized InfoPlist.stringsdict" "Contents/Resources holds an InfoPlist.* file" tree - Resources/en.lproj/InfoPlist.stringsdict=x
refused "an extension in upper case" "Contents/Resources holds an Info.plist or a nested bundle" tree - Resources/E.APPEX=x

[ "$failed" = 0 ] || { echo "check_app_selftest: the gate let a door through (above)" >&2; exit 1; }
echo "check_app_selftest: ok ($count doors refused)"
