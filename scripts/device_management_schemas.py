#!/usr/bin/env python3
"""Generate the configuration-profile schema contract from apple/device-management (plan §3.10, §2.1).

Apple's device-management repository describes every MDM profile payload as YAML: its payload type, the OS
versions that support it, and every payload key with its type, value type and presence. This script reads
`mdm/profiles/*.yaml` at one pinned commit and writes, deterministically (files by path, keys in the YAML's own order,
no timestamps), so a re-run at the same pin changes no byte:

    Contracts/device-management/profiles-<version>.json

Now: the contract `ProfileText`'s masking is held to. A key whose description says its value is a secret is marked
`describedAsSecret` (`SECRET`); the description itself isn't stored. The test holds every marked key to its reviewed
secret or not-secret list, so a secret Apple adds in a later release fails there before anyone writes it down.
Phase 5: the validation of a custom setting before upload.

Downloaded files are DATA: YAML read with `yaml.safe_load` and nothing else, capped in size and count, fetched
only over HTTPS from api.github.com (the tree, once) and raw.githubusercontent.com (each file at the pinned
commit), with no redirect followed. Each file's bytes are checked against the tree's git blob hash before they
are read. PyYAML runs only in a dev venv; the output is committed, so nothing in CI needs it:

    <a venv with PyYAML>/bin/python -I -B scripts/device_management_schemas.py --out Contracts/device-management

Apple's licence (MIT) travels with the data, in the output's `license` field.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

REPO = "apple/device-management"
COMMIT = "09f249a06e7e3289930bf6d05f38fb562f748ebf"   # the release branch's "Release-v27.0" (plan Appendix E)
RELEASE = "Release-v27.0"
VERSION = "27.0"
HOSTS = {"api.github.com", "raw.githubusercontent.com"}
MAX_FILES = 400           # 127 profile schemas at 27.0
MAX_BYTES = 2 * 1024 * 1024
DELAY = 0.05
PLATFORMS = ["iOS", "macOS", "tvOS", "visionOS", "watchOS"]

# Apple's own wording for a value that is a secret, read from every description at 27.0 (review M-2): "The password
# for/of the account", "The password used to authenticate", "The user's password", "The AirPlay password", "An optional
# user password", "The password to the identity"; "a preshared secret", "the shared secret"; "the Post-quantum Pre-shared
# key"; "The token this device uses", "an HTTP bearer token", "the per-user authentication token"; a challenge; "an
# anti-replay code"; a passphrase; a private key. Words that only name a secret elsewhere stay out: "token requests",
# "a token card", "the bootstrap token" (a capability), "a password to unlock" (a policy). Matched on the description
# with its whitespace collapsed, so `^` is its start.
SECRET = re.compile(r"""
    \bpassword\ (?:for|of|used)\b
  | ^(?:the|an?)\ (?:[\w']+\ ){0,2}password\b
  | \bthe\ user's\ password\b
  | \bsecret\b
  | \bpre-?shared\b
  | \b(?:the|bearer|authentication)\ token\b
  | \bchallenge\b
  | \banti-replay\b
  | \bpassphrase\b
  | \bprivate\ key\b
""", re.IGNORECASE | re.VERBOSE)


def described_as_secret(item: dict) -> bool:
    """Whether Apple's description says the key's value is a secret. A flag is never one: its description names the
    secret it governs (`AllowAllAppsAccess`: "access to the private key"), and `ProfileText` never masks a flag."""
    return item.get("type") != "<boolean>" and SECRET.search(" ".join(str(item.get("content") or "").split())) is not None


class NoRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect is refused before it is followed, so no request leaves the two hosts."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SystemExit(f"{req.full_url} redirected to {newurl}; refusing to follow")


OPENER = urllib.request.build_opener(NoRedirects)


def fetch(url: str) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in HOSTS:
        raise SystemExit(f"refusing to fetch {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "swiftabapit-contracts/1"})
    with OPENER.open(request, timeout=30) as response:
        body = response.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise SystemExit(f"{url} is larger than {MAX_BYTES} bytes")
    time.sleep(DELAY)
    return body


def blob_sha(body: bytes) -> str:
    """Git's object id for a file's bytes: what the tree names, so a file that isn't the commit's is refused."""
    return hashlib.sha1(b"blob %d\0" % len(body) + body).hexdigest()


def keys_of(items, prefix: list[str], seen: tuple[int, ...], out: list[dict]) -> None:
    """Every payload key, depth first in the YAML's order, with its path. A schema that names itself through a YAML anchor
    (an allow list's sub-apps, the Home Screen's pages) is marked `recursive` where it repeats, not walked again."""
    for item in items or []:
        if not isinstance(item, dict) or "key" not in item:
            continue
        path = prefix + [str(item["key"])]
        key = {"path": path, "type": item.get("type"), "valuetype": item.get("valuetype") or item.get("subtype"),
               "presence": item.get("presence")}
        if described_as_secret(item):
            key["describedAsSecret"] = True
        if id(item) in seen:
            out.append({**key, "recursive": True})
            continue
        out.append(key)
        keys_of(item.get("subkeys"), path, seen + (id(item),), out)


def supported(payload: dict) -> dict:
    """The OS each platform added the payload in, for the platforms that have it ("n/a" left out)."""
    os = payload.get("supportedOS") or {}
    return {name: str(os[name]["introduced"]) for name in PLATFORMS
            if isinstance(os.get(name), dict) and str(os[name].get("introduced", "n/a")) != "n/a"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True, help="Contracts/device-management")
    args = parser.parse_args()
    tree = json.loads(fetch(f"https://api.github.com/repos/{REPO}/git/trees/{COMMIT}?recursive=1"))
    if tree.get("truncated"):
        raise SystemExit("the tree listing is truncated")
    blobs = {t["path"]: t["sha"] for t in tree["tree"] if t["type"] == "blob"}
    files = sorted(p for p in blobs if p.startswith("mdm/profiles/") and p.endswith(".yaml"))
    if not files or len(files) > MAX_FILES:
        raise SystemExit(f"{len(files)} profile schemas; expected 1 to {MAX_FILES}")
    payloads = []
    for path in files + ["LICENSE.txt"]:
        body = fetch(f"https://raw.githubusercontent.com/{REPO}/{COMMIT}/{path}")
        if blob_sha(body) != blobs[path]:
            raise SystemExit(f"{path}: its bytes aren't the commit's ({blob_sha(body)} != {blobs[path]})")
        if path == "LICENSE.txt":
            license_text = body.decode("utf-8")
            continue
        doc = yaml.safe_load(body)
        payload = doc.get("payload") or {}
        keys: list[dict] = []
        keys_of(doc.get("payloadkeys"), [], (), keys)
        payloads.append({"file": path, "sha256": hashlib.sha256(body).hexdigest(), "payloadtype": payload.get("payloadtype"),
                         "supportedOS": supported(payload), "keys": keys})
    # Over the files' own SHA-256s, sorted, one per line: recomputable from the output alone (review L-6).
    whole = hashlib.sha256("".join(f"{h}\n" for h in sorted(p["sha256"] for p in payloads)).encode())
    result = {
        "source": f"https://github.com/{REPO}",
        "commit": COMMIT,
        "release": RELEASE,
        "pyyaml": yaml.__version__,
        "sha256": whole.hexdigest(),
        "counts": {"files": len(payloads), "keys": sum(len(p["keys"]) for p in payloads),
                   "describedAsSecret": sum(1 for p in payloads for k in p["keys"] if k.get("describedAsSecret"))},
        "license": license_text,
        "payloads": payloads,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    out = args.out / f"profiles-{VERSION}.json"
    out.write_text(json.dumps(result, indent=1, ensure_ascii=True) + "\n")
    print(f"{result['counts']} → {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
