# 2026-10-16 — The gate checked names, not values

- **Symptom:** Phase 0's adversarial review (PR #1) re-signed the Release app with
  `com.apple.security.app-sandbox` set to `<integer>0</integer>` and to `<string>NO</string>`, and
  `scripts/check_app.sh` printed `ok`. It also passed a second executable in `Contents/MacOS/` that imported
  `bind`/`listen`/`accept` and carried `network.server`, and a binary using `NWListener`.
  `PackageGraphTests` stayed green with `Assist` depending on `ChangeCore` and `HTTPCore` through a
  variable, a later `.append`, and a comment repeating an old line. The S1 spike put `kSecAttrService` on a
  key item. The contract crawler kept one example per page (`create-an-orgdeviceactivity` has five). The
  golden loader dropped a leading U+FEFF. The local hooks failed open in a worktree and missed `$HOME`,
  `~user`, glob and quoting variants.
- **Cause:** each check asserted the shape its author expected rather than what an attacker or a mistake
  would produce: entitlement key names instead of the whole dictionary; one known Mach-O path instead of
  every Mach-O; three listener symbol spellings; a regex over the manifest's text instead of the manifest
  SwiftPM evaluates; the line-oriented import scan; a password attribute copied onto a key; a file name per
  page; `JSONSerialization`'s string handling; relative hook paths.
- **Why not caught:** the hand mutants were the author's own (an extra key, sandbox `false`, no runtime),
  all of the shape the check already looked for. Nobody had tried a value of another type, an extra file or
  a computed manifest.
- **Fix:** PR #1, before merge: `check_app.sh` compares the entitlements dictionary whole (key and type and
  value), requires exactly one Mach-O, matches listener APIs broadly, refuses an ATS exception and debug
  switches in Release; `scripts/check_graph.py` reads `swift package dump-package`; `scripts/test.sh`
  builds with `--explicit-target-dependency-import-check error`; the import scan tokenizes (comments,
  strings, `;`, line breaks, modifiers); the spike tags its key and exits non-zero unless the signature
  verifies; the crawler numbers repeated examples and refuses redirects before following them; goldens
  are decoded with `JSONDecoder`; hooks use `$CLAUDE_PROJECT_DIR`, `python3 -I` and a normalized command;
  the fuzz target compares the parser with a plain reference.
- **Prevention:** each fix kept the reviewer's attack as a mutant it now kills (listed in the PR). The lesson
  for the `pre-commit` skill's review item: hand mutants come from an adversary's view, not the author's —
  the other type, the extra file, the computed value, the second example. A RULE-FEEDBACK entry records it.
