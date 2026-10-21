#!/usr/bin/env bash
# handoff-coverage/v1: every shipped example fragment and receipt validates;
# every invalid fixture in tests/fixtures/handoff-coverage fails with its
# expected finding; owner-keyed ext keys pass; a code prefix family resolves to
# its longest match; an outbox folder checks receipt names against content,
# skips dot entries and reports strays; two fragments cannot share a protocol
# id; a schema keyword the validator does not implement refuses the schema;
# one exit-code contract.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-coverage)

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import shutil
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
TOOL = str(root / "bin/fm-handoff-validate.py")
EXAMPLES = root / "docs/handoff-coverage/examples"
FIXTURES = root / "tests/fixtures/handoff-coverage"
FRAGMENT = EXAMPLES / "xp-chain.fragment.json"


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def run(*args):
    proc = subprocess.run([sys.executable, "-I", TOOL, *map(str, args)], capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def load(path):
    return json.loads(Path(path).read_text())


def write(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return path


fragments = sorted(EXAMPLES.glob("*.fragment.json"))
receipts = sorted(EXAMPLES.glob("receipt-*.json"))
expect(fragments and len(receipts) >= 4, "the examples folder ships a fragment and the worked receipts")
rc, out = run("fragment", *fragments)
expect(rc == 0, "every example fragment validates", out)
expect(load(FRAGMENT).get("example") is True, "the xp chain fragment is marked as an example")
rc, out = run("receipt", "--fragment", FRAGMENT, *receipts)
expect(rc == 0 and out.count("ok receipt") == len(receipts), "every example receipt validates against the registry", out)
states = {load(p)["state"] for p in receipts}
expect({"refused", "held", "waiting"} <= states, "the worked receipts cover refused, held and waiting", str(states))
expect(any(load(p).get("holds_all") for p in receipts), "a worked receipt is a holds_all lane fault")

cases = []
for line in (FIXTURES / "expected.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        name, want = line.split("\t", 1)
        cases.append((name, want))
listed = {name for name, _ in cases}
present = {p.name for p in FIXTURES.glob("*.json")}
expect(listed == present, "every invalid fixture has an expected finding", str(listed ^ present))
for name, want in cases:
    path = FIXTURES / name
    if name.startswith("fragment-"):
        rc, out = run("fragment", path)
    else:
        rc, out = run("receipt", "--fragment", FRAGMENT, path)
    expect(rc == 1 and want in out, f"{name} fails with: {want}", out)

# Readers ignore unknown owner-keyed extensions, at every level that has ext.
frag = load(FRAGMENT)
frag["ext"] = {"tetjet-mate.mirror": "d:/example", "research.weight": 2}
frag["protocols"][0]["stages"][0]["ext"] = {"lattice-research-mate.queue_hint": True}
rc, out = run("fragment", write(tmp / "ext/fragment.json", frag))
expect(rc == 0, "owner-keyed ext keys at the top and on a stage pass", out)
receipt = load(EXAMPLES / "receipt-done.json")
receipt["ext"] = {"some-future-home.anything": "x"}
rc, out = run("receipt", "--fragment", FRAGMENT, write(tmp / "ext/receipt.json", receipt))
expect(rc == 0, "an unknown owner-keyed ext key on a receipt passes", out)

# A code family resolves to the longest matching prefix: intake-* is holds_all.
held = load(EXAMPLES / "receipt-held-lane-fault.json")
held.update(code="intake-storage-lost")
rc, out = run("receipt", "--fragment", FRAGMENT, write(tmp / "family/held.json", held))
expect(rc == 0, "a code in a declared prefix family is accepted", out)
refused = load(EXAMPLES / "receipt-refused.json")
refused.update(stage="offer-intake", home="tetjet-mate", code="offer-refused:no-slot")
rc, out = run("receipt", "--fragment", FRAGMENT, write(tmp / "family/refused.json", refused))
expect(rc == 0, "a non-holds_all family on the same stage stays per-record", out)

# version-unsupported is reserved: any stage may refuse with it, unaccepted version and all.
refused = load(EXAMPLES / "receipt-refused.json")
refused.update(version=7, code="version-unsupported")
rc, out = run("receipt", "--fragment", FRAGMENT, write(tmp / "reserved/refused.json", refused))
expect(rc == 0, "a stage refuses an unaccepted version with the reserved code", out)

# Outbox: names derive from written_at and receipt_id; dot entries are staging.
box = tmp / "outbox"
for path in receipts:
    doc = load(path)
    stamp = doc["written_at"].replace("-", "").replace(":", "")
    write(box / f"{stamp}-{doc['receipt_id']}.json", doc)
write(box / ".tmp/20261021T000000.000000Z-0000000000000000.json", {"partial": True})
(box / ".synced-at").write_text("2026-10-21T12:00:00Z\n")
rc, out = run("outbox", "--fragment", FRAGMENT, box)
expect(rc == 0 and out.count("ok receipt") == len(receipts), "a well-named outbox validates and skips dot entries", out)
first = sorted(p for p in box.glob("*.json"))[0]
first.rename(box / ("20990101T000000.000000Z-" + first.name.split("-", 1)[1]))
(box / "notes.txt").write_text("stray\n")
rc, out = run("outbox", box)
expect(rc == 1 and "file name must be" in out and "notes.txt" in out and "an outbox holds only receipts" in out,
       "an outbox reports a name that does not match its content and a stray file", out)

# Protocol ids are unique across fragments.
other = load(FRAGMENT)
other["home"] = other["protocols"][0]["owner"] = "research"
rc, out = run("fragment", FRAGMENT, write(tmp / "dup/other.json", other))
expect(rc == 1 and "is also declared in" in out, "two fragments cannot declare the same protocol id", out)

# Fail closed on a schema this validator cannot fully enforce.
schemas = tmp / "schemas"
shutil.copytree(root / "docs/handoff-coverage", schemas, ignore=shutil.ignore_patterns("examples"))
reg = load(schemas / "handoff-registry-v1.schema.json")
reg["properties"]["revision"]["multipleOf"] = 1
write(schemas / "handoff-registry-v1.schema.json", reg)
rc, out = run("--schema-dir", schemas, "fragment", FRAGMENT)
expect(rc == 3 and "unsupported keyword multipleOf" in out, "an unsupported schema keyword refuses the schema", out)
rc, out = run("fragment", tmp / "missing.json")
expect(rc == 3, "an unreadable input exits 3", out)
rc, out = run("validate", FRAGMENT)
expect(rc == 2, "an unknown command exits 2", out)
rc, out = run("outbox", box, box)
expect(rc == 2, "outbox takes exactly one folder", out)
PY
pass "handoff-coverage/v1 schemas, examples and validator"
