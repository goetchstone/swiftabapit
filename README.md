# swiftabapit

[![CI](https://github.com/goetchstone/swiftabapit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/goetchstone/swiftabapit/actions/workflows/ci.yml)
[![CodeQL](https://github.com/goetchstone/swiftabapit/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/goetchstone/swiftabapit/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/goetchstone/swiftabapit/badge)](https://scorecard.dev/viewer/?uri=github.com/goetchstone/swiftabapit)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**abapit** as a native macOS app: a sandboxed SwiftUI front end for the
[Apple Business API](https://developer.apple.com/documentation/applebusinessapi) (2.6), the
[Apple School Manager API](https://developer.apple.com/documentation/appleschoolmanagerapi) (1.7) and
Mosyle Business, for Mac admins. It replaces [abapit](https://github.com/goetchstone/abapit), the
Python web tool, and its tests hold it to abapit's behaviour where abapit was right.

**Status: Phase 0 — scaffold.** Nothing talks to Apple or Mosyle yet. The repo has the project, the
package graph, CI, the Apple API contract manifests generated from Apple's own documentation, and the
parity goldens from frozen abapit. The plan and its phases are in
[docs/plans/2026-10-16-swift-port.md](docs/plans/2026-10-16-swift-port.md).

Not affiliated with Apple or Mosyle.

## How it's built to be safe

- **No server.** The app opens no port; it makes outbound HTTPS calls to five hosts only (Apple's token
  endpoint, the Business and School APIs, Mosyle's API and Logs Stream), and refuses a redirect anywhere
  else. App Sandbox and the hardened runtime are on; `scripts/check_app.sh` checks the exact entitlements.
- **Keys in the Keychain.** An Apple API key is imported once into the data-protection Keychain, this Mac
  only, behind Touch ID; tokens and signed assertions live only in memory. Mosyle credentials too.
- **One write path.** Every change is planned, shown as the exact request it will send, confirmed by you,
  checked again, and then that held request is sent and audited. Nothing else in the app can send a write.
- **On-device AI only drafts**, except a short, off-by-default list of single-device actions you can switch
  on per organization (play a sound, request a location, assign one device).
- **Zero third-party dependencies.**

## Building

macOS 27 and Xcode 27.

```bash
scripts/test.sh
xcodebuild -project SwiftAbapit.xcodeproj -scheme abapit -derivedDataPath build/DerivedData.noindex build
```

An ad-hoc build can't use the data-protection Keychain. To store keys, sign with your team (a free
Personal Team works): create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY =
Apple Development` and `CODE_SIGN_ENTITLEMENTS = Config/abapit-Team.entitlements`, then build once in
Xcode so it provisions the keychain access group.

## Live verification

Every write is unproven until it has run against a real organization on a scratch object
([live-verify](.claude/skills/live-verify/SKILL.md)). None is built yet.

| Write | Status |
|---|---|
| — | — |

## Working on it

Start with [CLAUDE.md](CLAUDE.md): the invariants, the rules of engagement and the self-improvement loop
(skills in `.claude/skills/`, the [failure log](docs/failure-log/README.md), the
[rule feedback ledger](docs/RULE-FEEDBACK.md), [runbooks](docs/domains/README.md)).
