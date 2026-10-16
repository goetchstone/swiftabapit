# How this repo teaches itself

Carried over from SwiftGamGui's `docs/FRAMEWORK.md` (itself from GamGUI's, built after weeks of
incidents). A solo-operator project has no second pair of eyes, and the keys this app holds make a
silent mistake expensive, so the structure has to make the model's review enforceable.

One sentence if you read nothing else: **rules earn their place by surviving incidents; each rule lives
in the layer that can actually enforce it; and the stub is guilty until proven faithful.**

## 1. Three layers of written context

| Layer | Where | Purpose | Loaded |
|---|---|---|---|
| **Constitution** | [`CLAUDE.md`](../CLAUDE.md) | Numbered invariants, each with its enforcement home | Every session |
| **Domain runbooks** | [`docs/domains/*.md`](domains/README.md) | Per-area files, flow, failure history, stub-lies traps, common tasks | On demand, by area |
| **Skills** | [`.claude/skills/*/SKILL.md`](../.claude/skills) | Procedures for a moment: start-session, pre-commit, add-api-operation, post-failure, live-verify, end-of-session, improve-rules | When the moment arrives |

When CLAUDE.md wants to grow, push the detail into a runbook and keep the invariant one line.

## 2. Three enforcement homes

| Home | What it is | Strength | Example here |
|---|---|---|---|
| **Skill** | A checklist the model reads when activated | Persuasive | `pre-commit`: "route the write through ChangeCore" |
| **Hook** | Code on a tool event; can hard-block | Hard gate | `.claude/hooks/pre-commit-check.sh` (private terms, `fix:` without a failure-log entry); `credential-guard.sh` |
| **Tripwire test** | A test that fails if a guard is missing or the stub lies | Backstop | `SourceScanTests` (the write chokepoint), `PackageGraphTests` (dependency edges), `ParityTests` |

**The compiler is the first home.** A `package` initializer the app can't call beats any scan; a scan
covers only what the compiler can't see.

**A hook only counts if its output reaches the model.** A SessionStart hook's stdout becomes context; a
non-blocking PreToolUse hook prints `{"hookSpecificOutput": {"hookEventName": "PreToolUse",
"additionalContext": "…"}}`; stderr reaches the model only on a blocking exit 2. GamGUI's hooks once
printed to stderr at exit 0 for weeks and nobody saw a line.

**Local vs shared.** `.claude/*` is gitignored except `skills/` and `agents/`: the knowledge is
committed; the enforcement wiring (`.claude/hooks/`, `.claude/settings.json`, `.claude/private-terms`)
stays local to the operator, as in SwiftGamGui. A `.git/hooks/pre-commit` that calls
`private-terms-check.sh` covers commits made outside a Claude session.

**Review skills are a probe, not a home.** `/code-review`, `/security-review` and the
`abapit-write-reviewer` agent find breaks; a real finding goes in RULE-FEEDBACK, and the rule it implies
still needs one of the three homes.

## 3. The learning loop

```
Something breaks (a test late, a live tenant, a regression, a review finding)
        ↓  post-failure skill
docs/failure-log/ entry: symptom / cause / why-not-caught / fix / prevention
        ↓
Recurring shape? ── yes ─→ a tripwire test that asserts it can't recur silently
        ↓ no
docs/RULE-FEEDBACK.md — which invariant strained, and how
        ↓  (sessions do NOT edit CLAUDE.md)
improve-rules — later, with distance — proposes ONE focused CLAUDE.md edit as a PR
```

The SessionStart hook `rules-improver-check.sh` counts `fix:`/`revert:` commits and open RULE-FEEDBACK
entries since the last pass and, past a threshold, tells the session to mention `/improve-rules` to the
operator.

SwiftGamGui's and GamGUI's failure logs stay the history this repo's rules came from; cite their
entries by repo and date ("SwiftGamGui failure-log 2026-10-10"). New incidents here get entries here.

## 4. The defining failure class: the stub lies

`AppleStub` and `MosyleStub` must **fail the way the real APIs fail**, checked against
`Contracts/apple/*.json`, `Contracts/mosyle/operations.json` and scrubbed recordings. A stub more
permissive than the API converts a live break into a green test. Passing the offline suite does not
mean a write works; a write is unproven until it has run against a real tenant, on a scratch object,
by the `live-verify` skill.

## 5. Where the reference is wrong

Parity (invariant 6) makes frozen abapit the oracle. Where abapit is wrong — the plan's §2.3 lists
twenty defects — the golden holds the **corrected** expectation and keeps abapit's output in an
`abapit` field beside it, and a test holds that deviation list narrow. SwiftGamGui learned this three
times in one week (its RULE-FEEDBACK 2026-10-10 and 2026-10-13): a faithful port copies the reference's
blind spots, and a stub written from the reference's view of the API shares them.
