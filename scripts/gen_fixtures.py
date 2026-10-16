#!/usr/bin/env python3
"""Generate the parity goldens in Tests/Fixtures/parity/ from frozen abapit (plan §6.2, invariant 6).

abapit (the Python app) is the behaviour reference. This script extracts abapit's package at the pinned
commit with `git archive` into a scratch directory, imports it from there (never from an installed
copy), runs each pure function over seeded generated inputs and hand-written edge cases, and writes what
it returned. Where abapit is wrong (plan §2.3), a case holds the CORRECTED expectation in `expected`
and abapit's own output in `abapit`; the Swift tests hold that deviation list narrow. Never edit a
golden by hand to make a test pass.

Corrections recorded here (the others in §2.3 are client behaviour, covered by the strict stubs):
  - serials: uppercase ASCII letters only (Python's str.upper() follows its Unicode version; a serial is
    ASCII, and a non-ASCII token matches no device either way);
  - csv: a dict or nested list cell is JSON (sorted keys), not Python's repr;
  - private keys: only P-256 is accepted (abapit accepts any key cryptography loads, then fails to sign);
  - mosyle adapt_device: no `activation_bypass*` key (defect 1);
  - mosyle compliance timestamps (`01:00 PM - 03/12/2024`, no zone) parse as local time (defect 5).

Inputs come only from `random.Random(seed)` and literals here — no Hypothesis, so an unrelated edit to
this file can't move a drawn case (SwiftGamGui RULE-FEEDBACK 2026-10-08). Run it with abapit's venv
(it needs `cryptography` and `PyJWT`), isolated:

    ../abapit/.venv/bin/python -I -B scripts/gen_fixtures.py --abapit ../abapit
"""

from __future__ import annotations

import argparse
import atexit
import base64
import copy
import importlib
import io
import json
import os
import platform
import random
import re
import shutil
import string
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

# abapit's main (the merge of PR #4). Its pure modules are identical to 9875ee7, which the plan was written
# at, but that commit lives only on an unmerged branch that may be deleted (Phase 0's review).
ABAPIT_PIN = "3890091ddc4e57372f45eb6b479ebf5fbcbbfa2f"
FIXED_NOW = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Tests" / "Fixtures" / "parity"

# Every code point Python's str.isspace() (and so `re`'s \s, and str.strip()) treats as whitespace.
PY_WHITESPACE = [c for c in range(0x110000) if chr(c).isspace()]


# -- loading abapit at the pin ---------------------------------------------------------------------

def load_abapit(repo: Path) -> dict:
    """abapit's modules, imported from a `git archive` of the pinned commit."""
    subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{ABAPIT_PIN}^{{commit}}"], check=True)
    archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", ABAPIT_PIN, "abapit"],
                             check=True, capture_output=True).stdout
    scratch = Path(tempfile.mkdtemp(prefix="abapit-pin-"))
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            if member.name.startswith("/") or ".." in Path(member.name).parts or not (member.isfile() or member.isdir()):
                raise SystemExit(f"unexpected archive member {member.name}")
        tar.extractall(scratch, filter="data")
    sys.path.insert(0, str(scratch))
    for name in list(sys.modules):
        if name == "abapit" or name.startswith("abapit."):
            del sys.modules[name]
    modules = {name: importlib.import_module(f"abapit.{name}")
               for name in ("assign", "blueprint_plan", "reports", "history", "config", "auth", "mosyle")}
    for module in modules.values():
        if not str(Path(module.__file__).resolve()).startswith(str(scratch.resolve())):
            raise SystemExit(f"{module.__name__} came from {module.__file__}, not the pinned archive")
    os.environ["ABAPIT_DATA_DIR"] = str(scratch / "data")
    os.environ["ABAPIT_CONFIG_DIR"] = str(scratch / "config")
    modules["scratch"] = scratch
    atexit.register(shutil.rmtree, scratch, ignore_errors=True)   # the throwaway keys written below go with it
    return modules


def header(seed: int | None) -> dict:
    return {"generator": "scripts/gen_fixtures.py", "abapit": ABAPIT_PIN, "python": platform.python_version(),
            "unicode": unicodedata.unidata_version, "seed": seed, "now": FIXED_NOW.isoformat()}


def write(name: str, payload: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    # Insertion order, never sorted: abapit's CSV columns are its attributes' first-seen order, so an input's
    # key order is part of the case. The generation is seeded, so the order is as deterministic as the values.
    text = json.dumps(payload, indent=1, ensure_ascii=True, default=str) + "\n"
    (OUT / f"{name}.json").write_text(text)
    print(f"{name}: {len(payload.get('cases', []))} cases", file=sys.stderr)


def jsonable(value):
    """abapit's outputs as JSON: tuples become lists, Counters and sets are already lists by now."""
    return json.loads(json.dumps(value, default=str))


def outcome(call):
    try:
        return {"ok": jsonable(call())}
    except Exception as error:  # noqa: BLE001 — the golden records abapit's refusal, whatever it is
        return {"error": type(error).__name__, "message": str(error)}


# -- shared generated data -------------------------------------------------------------------------

FAMILIES = ["Mac", "iPhone", "iPad", "AppleTV", "Watch", "Vision"]
MODELS = {"Mac": ["MacBook Air 13-inch (M3)", "Mac mini (M4)"], "iPhone": ["iPhone 16", "iPhone 15"],
          "iPad": ["iPad Air 11-inch (M2)"], "AppleTV": ["Apple TV 4K (3rd gen)"], "Watch": ["Apple Watch Series 10"],
          "Vision": ["Apple Vision Pro"]}


def fake_serial(rng: random.Random) -> str:
    """Obviously fake: TEST and eight letters or digits (tenant data never enters the repo)."""
    return "TEST" + "".join(rng.choices(string.ascii_uppercase + string.digits, k=8))


def iso(dt: datetime, style: int) -> str:
    if style == 0:
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    if style == 1:
        return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"
    if style == 2:
        return dt.isoformat()
    return dt.strftime("%Y-%m-%d")


def when(rng: random.Random, days_back: int = 2000, days_ahead: int = 0) -> str | None:
    roll = rng.random()
    if roll < 0.06:
        return None
    if roll < 0.08:
        return ""
    if roll < 0.09:
        return "not a date"
    offset = rng.uniform(-days_back, days_ahead)
    dt = FIXED_NOW + timedelta(days=offset, seconds=rng.randint(0, 86399))
    return iso(dt.replace(microsecond=rng.randint(0, 999) * 1000), rng.choice([0, 0, 0, 1, 2, 3]))


def device(rng: random.Random, serial: str | None = None) -> dict:
    family = rng.choice(FAMILIES)
    attrs = {"serialNumber": serial, "productFamily": family, "deviceModel": rng.choice(MODELS[family]),
             "status": rng.choice(["ASSIGNED", "UNASSIGNED"]), "addedToOrgDateTime": when(rng),
             "orderDateTime": when(rng, 2600)}
    for key in list(attrs):
        if attrs[key] is None and rng.random() < 0.5:
            del attrs[key]
    if rng.random() < 0.05:
        attrs["productFamily"] = ""
    sid = serial or fake_serial(rng)
    attrs["serialNumber"] = sid
    return {"type": "orgDevices", "id": sid, "attributes": attrs}


def fleet(rng: random.Random, low: int = 0, high: int = 30) -> list[dict]:
    return [device(rng) for _ in range(rng.randint(low, high))]


def servers(rng: random.Random, count: int) -> list[dict]:
    names = ["Mosyle", "Jamf Pro", "Kandji", "Apple Configurator", "Intune"]
    return [{"type": "mdmServers", "id": f"{0xA0 + i:02X}" + "".join(rng.choices("0123456789ABCDEF", k=30)),
             "attributes": {"serverName": names[i % len(names)], "serverType": "MDM"}} for i in range(count)]


def applecare(rng: random.Random, devices: list[dict]) -> list[dict]:
    rows = []
    for d in devices:
        for _ in range(rng.choice([0, 1, 1, 2])):
            rows.append({"type": "applecare", "id": f"{d['id']}:{rng.randint(0, 9)}", "attributes": {
                "serialNumber": d["id"], "status": rng.choice(["ACTIVE", "ACTIVE", "INACTIVE"]),
                "description": rng.choice(["Limited Warranty", "AppleCare+", "AppleCare for Enterprise"]),
                "endDateTime": when(rng, 400, 400), "startDateTime": when(rng, 900)}})
    return rows


# -- serials ---------------------------------------------------------------------------------------

def corrected_serials(raw: str) -> list[str]:
    """The Swift parser's spec: split on runs of Python whitespace, ',' and ';'; uppercase ASCII a-z
    only; drop empties; dedupe keeping the first."""
    seen, out = set(), []
    for token in re.split(r"[\s,;]+", raw.strip()):
        token = "".join(c.upper() if "a" <= c <= "z" else c for c in token.strip())
        if token and token not in seen:
            seen.add(token)
            out.append(token)
    return out


def gen_serials(m: dict) -> None:
    rng = random.Random(1001)
    literal = ["", "   ", "c02x", "a,b;c d", "A a", "c02x,  C02X", "\tx\ny\r\n", "x,,;;y", "a\u00a0b", "a\u2003b",
               "a\u001cb", "a\u200bb", "ab\u0085cd", "a\u3000b", "é", "straße", "ǆx", "ıd",
               "  lead and trail  ", "dup dup DUP", "x;y,z w\nv", "a\fb\vc", "SERIAL-1 serial-1", "\ufeffab"]
    seps = [" ", ",", ";", "\t", "\n", "\r\n", ", ", "\u00a0", "\u2028", "\x1c", "\x0b", "\x0c", "  ;  "]
    alphabet = string.ascii_letters + string.digits + "-_."
    extra = ["é", "ß", "ı", "ñ", "ǆ", "և"]
    cases = []
    for raw in literal + [None] * 220:
        if raw is None:
            tokens = []
            for _ in range(rng.randint(0, 12)):
                token = "".join(rng.choices(alphabet, k=rng.randint(1, 14)))
                if rng.random() < 0.01:
                    token += rng.choice(extra)
                if tokens and rng.random() < 0.15:
                    token = rng.choice(tokens).swapcase()
                tokens.append(token)
            raw = "".join(t + rng.choice(seps) for t in tokens)
            if rng.random() < 0.3:
                raw = rng.choice(seps) + raw
        abapit = m["assign"].parse_serials(raw)
        expected = corrected_serials(raw)
        case = {"input": raw, "expected": expected}
        if abapit != expected:
            case["abapit"] = abapit
        cases.append(case)
    write("serials", {**header(1001), "python_whitespace": PY_WHITESPACE, "cases": cases})


# -- assignment plans ------------------------------------------------------------------------------

def gen_assign(m: dict) -> None:
    rng = random.Random(1002)
    cases = []
    for index in range(90):
        devices = fleet(rng, 1, 25)
        if rng.random() < 0.2:
            devices[0]["id"] = devices[0]["id"].lower()
        svcs = servers(rng, rng.randint(1, 3))
        mapping = {s["id"]: [] for s in svcs}
        for d in devices:
            if rng.random() < 0.6:
                mapping[rng.choice(svcs)["id"]].append(d["id"] if rng.random() < 0.8 else d["id"].lower())
        requested = [rng.choice(devices)["id"] for _ in range(rng.randint(0, 8))]
        requested += [fake_serial(rng) for _ in range(rng.randint(0, 2))]
        requested = [s.lower() if rng.random() < 0.3 else s for s in requested]
        raw = rng.choice([" ", ",", "\n", "; "]).join(requested)
        action = rng.choice(["assign", "unassign"] + (["move"] if index % 30 == 0 else []))
        server_id = rng.choice(svcs)["id"] if index % 25 else "unknown-service"
        call = lambda: m["assign"].plan(raw, action, server_id, copy.deepcopy(devices), svcs, mapping)  # noqa: E731
        cases.append({"input": {"raw": raw, "action": action, "server_id": server_id, "devices": devices,
                                "servers": svcs, "server_device_ids": mapping}, "expected": outcome(call)})
    write("assign_plan", {**header(1002), "cases": cases})


def gen_blueprint_relationships(m: dict) -> None:
    rng = random.Random(1003)
    cases = []
    for index in range(60):
        catalog = {f"id-{i}": f"Item {i}" for i in rng.sample(range(40), rng.randint(0, 12))}
        current = rng.sample(sorted(catalog), rng.randint(0, len(catalog))) if catalog else []
        selected = [rng.choice(sorted(catalog)) for _ in range(rng.randint(0, 6))] if catalog else []
        selected += [f"id-{rng.randint(40, 50)}" for _ in range(rng.randint(0, 2))]
        if rng.random() < 0.2:
            selected.append("")
        op = rng.choice(["add", "remove"] + (["replace"] if index % 20 == 0 else []))
        call = lambda: m["blueprint_plan"].plan_relationship(op, selected, current, catalog)  # noqa: E731
        cases.append({"input": {"op": op, "selected_ids": selected, "current_ids": current, "catalog": catalog},
                      "expected": outcome(call)})
    write("blueprint_relationship", {**header(1003), "cases": cases})


# -- reports ---------------------------------------------------------------------------------------

class FrozenDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return FIXED_NOW if tz is not None else FIXED_NOW.replace(tzinfo=None)


def mosyle_like(rng: random.Random, serial: str | None = None) -> dict:
    family = rng.choice(["Mac", "iPhone", "iPad", "AppleTV"])
    attrs = {"productFamily": family, "deviceModel": rng.choice(MODELS[family]),
             "osVersion": rng.choice(["26.0", "26.0.1", "27.0", "18.6", "", None]),
             "lastCheckIn": when(rng, 120), "currentUser": rng.choice(["", "avery@example.com", "kai@example.com"]),
             "status": rng.choice(["enrolled", "pending", ""]), "enrolledAt": when(rng, 900),
             "lastMdmCheckIn": when(rng, 60), "lastPush": when(rng, 30)}
    sid = serial or fake_serial(rng)
    if rng.random() < 0.2:
        sid = sid.lower()
    return {"type": "orgDevices", "id": sid, "attributes": {k: v for k, v in attrs.items() if v is not None}}


AUDIT_TYPES = ["SUBSCRIPTION_CREATED", "SUBSCRIPTION_UPDATED", "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED",
               "DEVICE_ADDED_TO_ORG", "DEVICE_ASSIGNED_TO_SERVER", "DEVICE_UNASSIGNED_FROM_SERVER",
               "DEVICE_IS_ERASED", "ACCOUNT_PASSWORD_CHANGED", "ROLE_CREATED", "API_ACCOUNT_KEY_REVOKED"]


def audit_events(rng: random.Random, count: int) -> list[dict]:
    events = []
    for i in range(count):
        attrs = {"type": rng.choice(AUDIT_TYPES), "eventDateTime": when(rng, 60),
                 "outcome": rng.choice(["SUCCESS", "FAILURE", ""])}
        events.append({"type": "auditEvents", "id": f"evt-{i}", "attributes": attrs})
    return events


def gen_reports(m: dict) -> None:
    reports = m["reports"]
    reports.datetime = FrozenDatetime  # device_stats reads datetime.now() itself
    rng = random.Random(1004)
    cases = []

    def add(function, args, call):
        cases.append({"function": function, "input": args, "expected": outcome(call)})

    for _ in range(25):
        devices = fleet(rng, 0, 40)
        add("device_stats", {"devices": devices}, lambda: reports.device_stats(devices))
    for _ in range(20):
        devices = fleet(rng, 0, 20)
        svcs = servers(rng, rng.randint(0, 3))
        mapping = {s["id"]: [d["id"] for d in devices if rng.random() < 0.4] + ([fake_serial(rng)] if rng.random() < 0.3 else [])
                   for s in svcs}
        add("assignment_summary", {"devices": devices, "servers": svcs, "server_device_ids": mapping},
            lambda: reports.assignment_summary(devices, svcs, mapping))
    for _ in range(20):
        devices = fleet(rng, 0, 20)
        care = applecare(rng, devices) + applecare(rng, fleet(rng, 0, 3))
        days = rng.choice([0, 30, 90, 365])
        add("coverage_report", {"applecare_items": care, "devices": devices, "days": days},
            lambda: reports.coverage_report(care, devices, days, now=FIXED_NOW))
    for _ in range(20):
        devices = fleet(rng, 0, 25)
        care = applecare(rng, devices) if rng.random() < 0.7 else None
        years = rng.choice([1, 3, 4, 5])
        add("fleet_age_report", {"devices": devices, "applecare_items": care, "years": years},
            lambda: reports.fleet_age_report(devices, care, years, now=FIXED_NOW))
    for _ in range(15):
        events = audit_events(rng, rng.randint(0, 30))
        which = rng.choice(["SUBSCRIPTION_EVENTS", "DEVICE_LIFECYCLE_EVENTS"])
        add("audit_digest", {"events": events, "types": which},
            lambda: reports.audit_digest(events, getattr(reports, which)))
    for _ in range(20):
        shared = [fake_serial(rng) for _ in range(rng.randint(0, 10))]
        abm = [device(rng, s) for s in shared if rng.random() < 0.8] + fleet(rng, 0, 6)
        mosyle = [mosyle_like(rng, s) for s in shared if rng.random() < 0.8] + [mosyle_like(rng) for _ in range(rng.randint(0, 6))]
        if rng.random() < 0.2:
            abm.append({"type": "orgDevices", "id": "", "attributes": {}})
        add("reconcile_enrollments", {"abm_devices": abm, "mosyle_devices": mosyle},
            lambda: reports.reconcile_enrollments(abm, mosyle))
    for _ in range(20):
        abm = device(rng)["attributes"] if rng.random() < 0.8 else None
        mosyle = mosyle_like(rng)["attributes"] if rng.random() < 0.8 else None
        events = audit_events(rng, rng.randint(0, 5)) if rng.random() < 0.7 else None
        add("device_timeline", {"abm_attrs": abm, "mosyle_attrs": mosyle, "audit_events": events},
            lambda: reports.device_timeline(abm, mosyle, events))
    for _ in range(15):
        devices = [mosyle_like(rng) for _ in range(rng.randint(0, 30))]
        add("mosyle_os_breakdown", {"devices": devices}, lambda: reports.mosyle_os_breakdown(devices))
    for _ in range(15):
        devices = [mosyle_like(rng) for _ in range(rng.randint(0, 25))]
        days = rng.choice([0, 7, 30, 90])
        add("mosyle_stale_devices", {"devices": devices, "days": days},
            lambda: reports.mosyle_stale_devices(devices, days, now=FIXED_NOW))
    for value in ["2024-03-01T10:00:00Z", "2024-03-01T10:00:00.123Z", "2024-03-01T10:00:00+00:00",
                  "2024-03-01T10:00:00.123456+02:00", "2024-03-01", "2024-03-01T10:00", "2024-03-01 10:00:00",
                  "20240301", "2024-03-01T10:00:00", "2024-13-01", "", None, "not a date", "2024-03-01T10:00:00ZZ",
                  "2024-03-01T24:00:00Z", "2024-W09", "2024-03-01T10:00:00.5Z", "  2024-03-01  ",
                  "2024-03-01T10:00:00,5Z", "2024-03-01T10", "2024-03-01T1000", "2024-03-01T10:00:00.1234567Z",
                  "2024-03-01T10:00:00+0530", "2024-03-01T10:00:00+05", "2024-03-01T10:00:00-00:00", "2024-03",
                  "2024-03-01T10:00:00 +00:00", "2024-02-29", "2023-02-29", "2024-03-01T10:00:60Z",
                  "2024-03-01T10:00:00+24:00", "2024-03-01T23:59:59.999999-12:00", "0001-01-01", "9999-12-31T23:59:59Z"]:
        parsed = reports.parse_iso(value)
        abapit = parsed.isoformat() if parsed else None
        # Python 3.11+ reads ISO week dates and a space before the offset; neither appears in Apple's or
        # Mosyle's data, and the Swift parser refuses both (a listed deviation).
        corrected = None if isinstance(value, str) and ("W" in value or " +" in value) else abapit
        case = {"function": "parse_iso", "input": {"value": value}, "expected": {"ok": corrected}}
        if corrected != abapit:
            case["abapit"] = {"ok": abapit}
        cases.append(case)
    for _ in range(10):
        attrs = rng.choice([{"deviceModel": "iPhone 16"}, {"name": "Sales"}, {"serverName": "Mosyle", "name": ""},
                            {"managedAppleAccount": "avery@example.com"}, {"description": "AppleCare+"}, {},
                            {"deviceModel": "", "name": None, "description": 0}, {"name": 5}])
        cases.append({"function": "item_label", "input": {"attributes": attrs},
                      "expected": {"ok": m["history"].item_label(attrs)}})
    write("reports", {**header(1004), "cases": cases})


# -- CSV -------------------------------------------------------------------------------------------

def corrected_cell(value) -> str:
    """abapit's _cell, with JSON for containers instead of Python's repr."""
    if value is None:
        return ""
    if isinstance(value, dict):
        return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "; ".join(corrected_cell(v) if isinstance(v, (dict, list)) else str(v) for v in value)
    return str(value)


def corrected_csv(m: dict, items: list[dict]) -> str:
    reports = m["reports"]
    columns: list[str] = []
    for item in items:
        for key in item.get("attributes", {}):
            if key not in columns:
                columns.append(key)
    rows = [["id"] + columns] + [[item.get("id", "")] + [corrected_cell(item.get("attributes", {}).get(c)) for c in columns]
                                 for item in items]
    import csv as pycsv
    buffer = io.StringIO()
    writer = pycsv.writer(buffer)
    writer.writerows([[reports._csv_safe(cell) for cell in row] for row in rows])
    return buffer.getvalue()


def gen_csv(m: dict) -> None:
    rng = random.Random(1005)
    risky = ["=SUM(A1)", "+1", "-1", "@cmd", "\tx", "\rx", "a,b", 'say "hi"', "line\nbreak", "cr\rlf", " lead", "trail ",
             "", "été", "日本", "'quoted", "=", "plain"]
    scalars = [None, True, False, 0, 5, -3, 0.81, 64.0, 1e-05, 1e16, 2.5]
    cases = []
    for _ in range(70):
        items = []
        keys = rng.sample(["serialNumber", "deviceModel", "=formula", "status", "tags", "notes", "meta", "count",
                           "ratio", "name", "@at"], rng.randint(0, 6))
        for i in range(rng.randint(0, 6)):
            attrs = {}
            for key in keys:
                if rng.random() < 0.15:
                    continue
                roll = rng.random()
                if roll < 0.45:
                    attrs[key] = rng.choice(risky)
                elif roll < 0.7:
                    attrs[key] = rng.choice(scalars)
                elif roll < 0.85:
                    attrs[key] = [rng.choice(risky + ["x", "y"]) for _ in range(rng.randint(0, 3))]
                elif roll < 0.93:
                    attrs[key] = {"b": rng.choice(risky), "a": rng.choice(scalars)}
                else:
                    attrs[key] = [{"id": "x", "n": 1}, "y"]
            items.append({"type": "orgDevices", "id": rng.choice(["", "TEST1", "=id", f"TEST{i}"]), "attributes": attrs})
        abapit = m["reports"].items_to_csv(items)
        expected = corrected_csv(m, items)
        case = {"input": items, "expected": expected}
        if abapit != expected:
            case["abapit"] = abapit
        cases.append(case)
    write("csv", {**header(1005), "cases": cases})


# -- snapshot diffs --------------------------------------------------------------------------------

def gen_diff(m: dict) -> None:
    history = m["history"]
    rng = random.Random(1006)
    cases = []
    conn = history.connect()
    for _ in range(40):
        def snapshot_data():
            data = {}
            for resource in rng.sample(["devices", "mdm_servers", "assignments", "applecare", "users"], rng.randint(0, 4)):
                data[resource] = {}
                for i in rng.sample(range(12), rng.randint(0, 8)):
                    data[resource][f"id-{i}"] = {"name": rng.choice(["A", "B", "C"]), "count": rng.choice([1, 2, None]),
                                                 "tags": rng.choice([["x"], ["x", "y"], []])}
                    if rng.random() < 0.3:
                        data[resource][f"id-{i}"]["extra"] = rng.choice(["e", 1.5, False])
            return data
        old = snapshot_data()
        new = copy.deepcopy(old) if rng.random() < 0.5 else snapshot_data()
        for resource in new:
            for key in list(new[resource]):
                if rng.random() < 0.2:
                    new[resource][key]["name"] = rng.choice(["A", "B", "Z"])
                if rng.random() < 0.1:
                    del new[resource][key]
        ids = []
        with conn:
            for data in (old, new):
                cur = conn.execute("INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors) "
                                   "VALUES ('2026-10-16T12:00:00Z', 'gen', 'Gen', 'business', '0.2.0', '{}')")
                ids.append(cur.lastrowid)
                for resource, items in data.items():
                    conn.executemany("INSERT INTO items VALUES (?, ?, ?, ?)",
                                     [(cur.lastrowid, resource, key, json.dumps(attrs, sort_keys=True)) for key, attrs in items.items()])
        cases.append({"input": {"old": old, "new": new}, "expected": outcome(lambda: history.diff_snapshots(ids[0], ids[1]))})
    conn.close()
    write("diff", {**header(1006), "cases": cases})


# -- private keys and the client assertion ---------------------------------------------------------

def gen_keys_and_claims(m: dict) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    import jwt

    def pem(key, fmt) -> str:
        return key.private_bytes(serialization.Encoding.PEM, fmt, serialization.NoEncryption()).decode()

    sec1, pkcs8 = serialization.PrivateFormat.TraditionalOpenSSL, serialization.PrivateFormat.PKCS8
    # Throwaway keys from fixed scalars: deterministic, and never used for anything real.
    keys = [ec.derive_private_key(scalar, ec.SECP256R1()) for scalar in (0x1111, 0xC0FFEE * 0x10001, 2**255 - 19)]
    p384 = ec.derive_private_key(0x2222, ec.SECP384R1())

    def swap(text: str) -> str:
        if "BEGIN EC PRIVATE KEY" in text:
            return text.replace("BEGIN EC PRIVATE KEY", "BEGIN PRIVATE KEY").replace("END EC PRIVATE KEY", "END PRIVATE KEY")
        return text.replace("BEGIN PRIVATE KEY", "BEGIN EC PRIVATE KEY").replace("END PRIVATE KEY", "END EC PRIVATE KEY")

    inputs = []
    for key in keys:
        scalar = f"{key.private_numbers().private_value:064x}"
        for name, text in [("sec1", pem(key, sec1)), ("pkcs8", pem(key, pkcs8))]:
            inputs += [(f"{name}", text, scalar), (f"{name}-crlf", text.replace("\n", "\r\n"), scalar),
                       (f"{name}-cr", text.replace("\n", "\r"), scalar), (f"{name}-mislabelled", swap(text), scalar),
                       (f"{name}-padded", "\n\n  " + text.strip() + "  \n\n", scalar),
                       (f"{name}-no-newline", text.strip(), scalar)]
    # No RSA or real encrypted key: their generation is random, and a golden must not move between runs.
    inputs += [("p384", pem(p384, pkcs8), None), ("p384-sec1", pem(p384, sec1), None), ("empty", "", None),
               ("garbage", "-----BEGIN PRIVATE KEY-----\nnot base64\n-----END PRIVATE KEY-----\n", None),
               ("public", keys[0].public_key().public_bytes(serialization.Encoding.PEM,
                                                            serialization.PublicFormat.SubjectPublicKeyInfo).decode(), None),
               ("truncated", pem(keys[0], pkcs8)[:120] + "\n-----END PRIVATE KEY-----\n", None),
               ("encrypted-label", "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIGHAgEAMBMG\n-----END ENCRYPTED PRIVATE KEY-----\n", None)]
    cases = []
    for name, text, scalar in inputs:
        result = outcome(lambda: m["config"].normalize_private_key(text))
        accepted = "ok" in result
        expected = {"accepted": scalar is not None, "scalar": scalar}
        case = {"name": name, "input": text, "expected": expected}
        if accepted:
            case["normalized"] = result["ok"]   # abapit's canonical PKCS#8 PEM, for reference
        if accepted != expected["accepted"]:
            case["abapit"] = {"accepted": accepted}
        cases.append(case)
    write("private_keys", {**header(None), "cases": cases})

    claims = []
    scratch = m["scratch"]
    for index, (client_id, key_id, team_id) in enumerate([
            ("BUSINESSAPI.00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-0000000000aa", ""),
            ("SCHOOLAPI.00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-0000000000bb", "TEAM000001")]):
        key_path = scratch / f"claims-{index}.pem"
        key_path.write_text(pem(keys[index], pkcs8))
        org = m["config"].Org(name="Example", scope=["business", "school"][index], client_id=client_id, key_id=key_id,
                              private_key_path=str(key_path), team_id=team_id)
        token = m["auth"].build_client_assertion(org, now=1_790_000_000)
        payload = jwt.decode(token, options={"verify_signature": False})
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", payload.pop("jti")):
            raise SystemExit("jti is not a UUID4")
        signature = base64.urlsafe_b64decode(token.split(".")[2] + "==")
        claims.append({"input": {"client_id": client_id, "key_id": key_id, "team_id": team_id, "scope": org.scope,
                                 "now": 1_790_000_000},
                       "expected": {"header": jwt.get_unverified_header(token), "payload": payload,
                                    "jti": "uuid4", "signature_bytes": len(signature),
                                    "token_scope": m["auth"].SCOPES[org.scope], "token_url": m["auth"].TOKEN_URL}})
    write("auth_claims", {**header(None), "cases": claims})


# -- Mosyle adapters -------------------------------------------------------------------------------

COMPLIANCE = re.compile(r"^(\d{1,2}):(\d{2}) (AM|PM) - (\d{2})/(\d{2})/(\d{4})$")


def compliance_time(value) -> str | None:
    """Defect 5: Mosyle's compliance timestamp, no zone given, read as local time (no suffix)."""
    match = COMPLIANCE.match(value) if isinstance(value, str) else None
    if not match:
        return None
    hour, minute, half, month, day, year = match.groups()
    hour = int(hour) % 12 + (12 if half == "PM" else 0)
    try:
        return datetime(int(year), int(month), int(day), hour, int(minute)).strftime("%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def raw_mosyle_device(rng: random.Random) -> dict:
    os_value = rng.choice(["ios", "mac", "tvos", "visionos", "", "macos", "watchos", None])
    raw = {"serial_number": fake_serial(rng) if rng.random() < 0.9 else "",
           "deviceudid": "".join(rng.choices("0123456789abcdef", k=24)),
           "device_name": rng.choice(["Avery's Mac", "iPad 3", "", "Lobby TV"]),
           "device_model": rng.choice(["Mac15,12", "iPad12,1", "iPhone17,3", "AppleTV14,1", ""]),
           "device_model_name": rng.choice(["MacBook Air", "iPad (9th generation)", "", "iPhone 16"]),
           "osversion": rng.choice(["26.0", "18.6", ""]), "status": rng.choice(["enrolled", "pending"]),
           "is_supervised": rng.choice(["1", "0", 1, True]), "battery": rng.choice(["0.81", "1", None]),
           "total_disk": rng.choice(["64.0000000000", "256", None]),
           "date_last_beat": rng.choice([str(1_790_000_000 - rng.randint(0, 10**7)), "", None, "2026-10-01", "junk"]),
           "date_enroll": rng.choice([1_700_000_000, "1700000000", None]),
           "lostmode_status": rng.choice(["DISABLED", "ENABLED", "PENDINGTOENABLE"]),
           "tags": rng.choice(["", "a,b", None]), "custom_field": "x"}
    if os_value is not None:
        raw["os"] = os_value
    if rng.random() < 0.6:
        raw["activation_bypass"] = "TESTBYPASS-" + "".join(rng.choices(string.ascii_uppercase, k=8))
    if rng.random() < 0.4:
        raw["activation_bypass_mdm"] = "TESTBYPASSMDM-" + "".join(rng.choices(string.ascii_uppercase, k=8))
    if rng.random() < 0.3:
        raw["CurrentConsoleManagedUser"] = "avery"
    return {k: v for k, v in raw.items() if v is not None or rng.random() < 0.3}


def gen_mosyle(m: dict) -> None:
    mosyle = m["mosyle"]
    rng = random.Random(1007)
    cases = []
    for _ in range(60):
        raw = raw_mosyle_device(rng)
        abapit = jsonable(mosyle.adapt_device(raw))
        expected = copy.deepcopy(abapit)
        expected["attributes"] = {k: v for k, v in expected["attributes"].items() if not k.startswith("activation_bypass")}
        case = {"function": "adapt_device", "input": raw, "expected": expected}
        if expected != abapit:
            case["abapit"] = abapit
        cases.append(case)
    for _ in range(25):
        raw = {k: v for k, v in {"iduser": rng.choice([str(rng.randint(1, 999)), rng.randint(1, 999), None]),
                                 "identifier": rng.choice(["avery", "", None]), "name": rng.choice(["Avery Chen", ""]),
                                 "email": rng.choice(["avery@example.com", "", None]),
                                 "managedappleid": rng.choice(["avery@appleid.example.com", None]),
                                 "type": rng.choice(["student", "teacher", None]), "usertype": rng.choice(["admin", None])}.items()
               if v is not None}
        cases.append({"function": "adapt_user", "input": raw, "expected": jsonable(mosyle.adapt_user(raw))})
    for _ in range(25):
        raw = {k: v for k, v in {"idusergroup": rng.choice(["7", None]), "iddevicegroup": rng.choice(["9", 9, None]),
                                 "id": rng.choice(["11", None]), "name": rng.choice(["Sales", ""]),
                                 "device_numbers": rng.choice([3, "3", None]),
                                 "idusers_primary": rng.choice([["1", "2"], [], "x", None]),
                                 "members": rng.choice([5, None]), "os": rng.choice(["ios", "mac", None])}.items()
               if v is not None}
        kind = rng.choice(["userGroups", "deviceGroups"])
        cases.append({"function": "adapt_group", "input": {"raw": raw, "kind": kind},
                      "expected": jsonable(mosyle.adapt_group(raw, kind))})
    for value in [None, "", "1700000000", 1700000000, " 1700000000", "+1700000000", "0", "-1", "1.5", "abc",
                  "99999999999999999999", "2024-03-12", "2024-03-12 10:00:00", "2024-3-12", "01:00 PM - 03/12/2024",
                  "12:30 AM - 01/02/2025", "1e9", True, 3.7]:
        abapit = mosyle._to_iso(value)
        cases.append({"function": "to_iso", "input": {"value": value}, "expected": abapit})
    for value in ["01:00 PM - 03/12/2024", "12:30 AM - 01/02/2025", "12:05 PM - 12/31/2023", "13:00 PM - 03/12/2024",
                  "01:00 PM - 02/30/2024", "1:07 AM - 07/04/2026", "01:00 pm - 03/12/2024", "", None]:
        cases.append({"function": "compliance_time", "input": {"value": value}, "expected": compliance_time(value)})
    for _ in range(30):
        def logs(kind):
            out = []
            for i in range(rng.randint(0, 3)):
                stamp = rng.choice([str(1_790_000_000 - rng.randint(0, 10**6)), "01:00 PM - 03/12/2024",
                                    "2026-10-01T10:00:00Z", "", None])
                out.append({"compliance": {"Timestamp": stamp, "RuleName": f"Rule {i}", "Status": "Failed",
                                           "DeviceName": "Mac", "SerialNumber": fake_serial(rng), "E-mail": "avery@example.com"},
                            "zero_trust": {"Timestamp": stamp, "Application": rng.choice(["Slack", None]),
                                           "FileName": "a.dmg", "Action": "Blocked", "Device": "Mac", "Source": "kai"},
                            "action_logs": {"ActionDate": stamp, "Action": "Wipe requested", "UserName": rng.choice(["admin", None]),
                                            "E-mail": "admin@example.com"},
                            "dns": {"Timestamp": stamp, "Domain": "example.com", "Action": "Allowed", "Device": "iPad"},
                            "av": {"Timestamp": stamp, "FileName": "x.exe", "Status": "Quarantined", "DeviceName": "Mac",
                                   "SerialNumber": fake_serial(rng)}}[kind])
            return out
        response = {}
        if rng.random() < 0.7:
            response["compliance"] = {"mac": {"Logs": logs("compliance")}, "ios": {"Logs": logs("compliance")}}
        if rng.random() < 0.5:
            response["zero_trust"] = rng.choice([{"Events": {"Logs": logs("zero_trust")}}, {"Logs": logs("zero_trust")}])
        if rng.random() < 0.5:
            response["action_logs"] = {"Logs": logs("action_logs")}
        if rng.random() < 0.4:
            response["dns"] = rng.choice([logs("dns"), {"Logs": logs("dns")}])
        if rng.random() < 0.4:
            response["av"] = {"Logs": logs("av")}
        abapit = jsonable(mosyle.normalize_logs(response))
        expected = copy.deepcopy(abapit)
        for event in expected:
            if event["kind"] == "compliance":
                event["when"] = compliance_time(event["when"]) or event["when"]
        expected.sort(key=lambda e: e["when"], reverse=True)
        case = {"function": "normalize_logs", "input": response, "expected": expected}
        if expected != abapit:
            case["abapit"] = abapit
        cases.append(case)
    write("mosyle", {**header(1007), "cases": cases})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--abapit", type=Path, required=True, help="a checkout of abapit holding the pinned commit")
    args = parser.parse_args()
    modules = load_abapit(args.abapit.resolve())
    gen_serials(modules)
    gen_assign(modules)
    gen_blueprint_relationships(modules)
    gen_reports(modules)
    gen_csv(modules)
    gen_diff(modules)
    gen_keys_and_claims(modules)
    gen_mosyle(modules)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
