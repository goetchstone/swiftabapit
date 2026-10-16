# Security Policy

## Reporting a vulnerability

Please report it **privately**, not in a public issue: a public report on a tool that holds keys able to
move or release an organization's devices is itself a risk to everyone running it.

Use GitHub's private reporting on this repository: **Security → Report a vulnerability**
([direct link](https://github.com/goetchstone/swiftabapit/security/advisories/new)). If that page isn't
available to you, open a public issue with **no details** that asks for a private channel, and the
maintainer will follow up.

Say what you did, what happened, and what you expected. A proof of concept helps a lot. This is a small
volunteer project: expect a reply in days, not hours.

## What abapit is, for threat modelling

abapit (this repository, swiftabapit) is a **local, single-operator macOS app**. It has no server, no
listener, no hosted service and no remote users. It calls Apple's and Mosyle's APIs over HTTPS and
nothing else.

The stakes are high because of what the app can reach:

> An Apple Business API key whose role allows writes can **assign every device in the organization to
> another MDM**, or **release devices from the organization for good**. Mosyle admin credentials can lock
> or wipe devices. Anything that exposes those, or makes the app send a request the operator didn't
> confirm, is serious.

**In scope:**

- another **local process** running as the same user, reading keys or tokens at rest;
- **hostile or malformed data from Apple or Mosyle** reaching a request the app builds, a parser, a log,
  a CSV export or the screen;
- **a model or Siri** causing a change the operator didn't confirm (beyond the operator's own
  off-by-default safe-actions list);
- **supply chain:** a compromised GitHub Action.

**Out of scope:** rate limiting, multi-user authorization (there is one operator), and anything that needs
an attacker who already has root or can modify the app bundle.

## Properties the code is expected to hold

Each is an invariant in [CLAUDE.md](CLAUDE.md); a change that breaks one is a bug, and tests guard them.

- **Keys live in the Keychain** (data-protection, this device only, user presence). Bearer tokens, signed
  assertions and Mosyle sessions live only in memory and are never printed.
- **One write path**: a planner builds the exact request, the operator confirms the preview, a guard inside
  the executor checks it again, and the held bytes are what is sent and audited. The ticket the transport
  requires is `package`-scoped; source-scan tests cover what the compiler can't see.
- **No listener, App Sandbox on, five allowlisted hosts**, hardened runtime, exact entitlements.
- **Sensitive fields never leave the app**: Activation Lock bypass codes, tokens, assertions, passwords —
  not in logs, audit records, CSV exports or errors.
- **Zero third-party dependencies**; every GitHub Action is pinned by commit SHA and the fuzzing container
  by digest.

## Known limitations

- **There are no released builds.** Build it yourself; a build is signed for your own Mac (a Personal
  Team), not notarized.
- A guard can't prove an API call does what you expect against *your* organization. Check the README's
  live-verification table, and rehearse anything unproven on a scratch device first.
- abapit is provided **as-is under the MIT License, with no warranty**. You are responsible for what you
  run against your own organization.
