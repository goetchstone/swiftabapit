# 2026-11-27 — The gate's fixes had no test that fails when they are undone

- **Symptom:** a review on 2026-11-18 cut `scripts/check_app.sh`'s entitlement compare back to key names
  (`same = got.keys() == want.keys()`) in a scratch copy. The gate printed `ok` for a sandbox entitlement of
  `0`, `"NO"`, `1` and `"true"`, and nothing in the repo failed: `scripts/test.sh` and CI ran the gate and
  `scripts/check_graph.py` on the good tree only. The graph check with its edge compare removed passed the same
  way.
- **Cause:** 3a1a381 (Phase 0's review fix) proved the gate by hand runs listed in PR #1, and later gate fixes
  did the same (`docs/domains/gates.md`: "list them in the PR"). The 2026-10-16 entry "the gate checked names,
  not values" says each fix "kept the reviewer's attack as a mutant it now kills"; the mutants were kept only
  as text in the PR.
- **Why not caught:** `post-failure` step 2 (the reproduction becomes the regression test) was read as met by
  a recorded hand run. That run was weaker than it looked: the four sandbox-value mutants were copies named
  `a.app`, and the gate refuses any copy not named `abapit.app` for its name alone, so their `exit 1` showed
  nothing about the entitlement compare. The debug-switch check added in the same commit could not fail
  (2026-10-16, "the gate looked for what it could not see").
- **Fix:** this PR. `scripts/check_app_mutants.sh` makes 24 changed copies of the Release app (six entitlement
  sets, no hardened runtime, a second Mach-O, two listeners, four environment, argument or defaults reads, a
  child process, a debug string, a debug-only name that only the symbol table shows, six imports that reach a host another way (socket and resolver calls, LSOpen, Host, NSWorkspace, WKWebView, SwiftUI's WebView), an ATS exception), and `scripts/check_graph_selftest.py` mutant manifests.
  Each must be refused, and an app mutant only for the reason named beside it. CI runs the first after the
  gate; `scripts/test.sh` runs the second.
- **Prevention:** the two scripts are the tripwire, and both were seen failing: against the gate with the
  entitlement compare cut to key names the app mutants script exits 1 (4 mutants pass), against the pre-fix
  gate of 8889c8b it exits 1 (14 pass), and the graph self-test exits 1 with the edge compare removed. A new
  gate rule gets its mutant there in the same PR (`docs/domains/gates.md`).
- **Extended (2026-11-27):** the same review weakened the three gate scripts one rule at a time: each of the 12
  refusals `scripts/check_graph.py` can print, 9 single changes to `scripts/check_text.py` (a clause of
  `invisible` dropped, the exit status, the exemption widened) and six of the Release gate's code checks. Every
  weakened copy still passed the clean tree, which is all CI ran. `scripts/check_graph_selftest.py` now holds 15
  mutant manifests, one for each refusal; `scripts/check_text_selftest.py` (CI's hygiene job) holds 14 files;
  and `scripts/check_app_mutants.sh` has a mutant for a debug-only name that only the symbol table shows, and six for the host-route refusal (failure-log 2026-11-18) that had none.
  With the gate's symbol-table search deleted the others were all still refused, so the script stayed green;
  it is the search the pipe of 2026-10-16 blinded. Each of the three was seen failing on each weakened copy.
