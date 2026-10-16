# Domain runbooks

Read the runbook for an area **before** working in it. Each carries the area's files, flow, failure
history and stub-lies traps. SwiftGamGui's runbook of the nearest area (in its `docs/domains/`) is the
history the design inherits; read it too while ours is a stub.

| Area | Runbook | Status |
|---|---|---|
| Keychain, key import, the Vault session, ES256 signing | [auth-keychain.md](auth-keychain.md) | phase 0: spike S1 written, operator run pending |
| HTTP core, hosts, rate limits, retries, paging | [http-core.md](http-core.md) | stub (phase 1) |
| Apple reads: devices, services, people, content, audit | [apple-reads.md](apple-reads.md) | stub (phases 1–2) |
| Apple writes: assignment, blueprints, configurations, services, migration, release | [apple-writes.md](apple-writes.md) | stub (phases 4–6) |
| Mosyle: session, envelope, devices, people, groups, lost mode | [mosyle.md](mosyle.md) | stub (phases 7–8) |
| Mosyle Logs Stream: the consuming drain | [logs-stream.md](logs-stream.md) | stub (phase 7) |
| History: snapshots, diff, reports, abapit import | [history.md](history.md) | stub (phase 3) |
| ChangeCore: preview, guard, executor, audit | [change-core.md](change-core.md) | stub (phase 4) |
| Assist, App Intents, Spotlight | [assist-intents.md](assist-intents.md) | stub (phase 9) |
| Contracts: Apple's DocC manifest and the drift job | [contracts.md](contracts.md) | phase 0: crawler and manifest |
| The gates: source scans and the Release gate (`check_app.sh`) | [gates.md](gates.md) | phase 1b: scanner self-tests, debug-only scans, stripped gate |

Template for a filled runbook: **One line** · **Owns invariant(s)** · **Enforcement home** · Files ·
How it works · Invariants & failure history · Gotchas / stub-lies traps · Testing / live-verification
status · To do common tasks here.
