"""Reader-first contracts for a future foreground read-service owner.

Only bounded record inspection and candidate construction live here. None of
these functions writes a receipt, publishes a fragment, binds a listener,
loads selected service code, acquires a singleton or signals a process.
The eventual effect owner must revalidate all observations and durably commit
a validated receipt before acting. Structural validation is NOT that gate.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re

from fm_handoff_registry import validator
from fm_view_bundle import directory, packed, read_regular, require, unique
from fm_view_process import ProcessGeneration
from fm_view_protocol import MAX_WORKERS

SCHEMA = "fm-view-lifecycle.v1"
OWNER_SCHEMA = "fm-view-owner.v1"
VERSION = 1
LIMIT = 64 * 1024
HOME_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,63}\Z")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
CODES = {
    "input-invalid": "A lifecycle input is malformed or unsupported.",
    "identity-changed": "An explicitly selected root, code or process identity changed.",
    "effect-failed": "A receipted lifecycle effect failed or its completion is unknown.",
}


def object_fields(value, names, what):
    require(type(value) is dict and set(value) == set(names.split()), "invalid " + what + " fields")


def token(value, what):
    require(type(value) is str and TOKEN.fullmatch(value), "invalid " + what)


def pair(value, what):
    require(type(value) is list and len(value) == 2
            and all(type(item) is int and item >= 0 for item in value), "invalid " + what)


def path(value, what):
    require(type(value) is str and value.startswith("/") and not value.startswith("//")
            and not any(ord(character) < 32 for character in value)
            and str(Path(value)) == value and ".." not in Path(value).parts, "invalid " + what)
    return Path(value)


def read_json(filename):
    return decode(read_regular(filename, LIMIT, 0o600))


def decode(raw):
    require(bool(raw.strip()) and raw.endswith(b"\n") and b"\0" not in raw, "incomplete lifecycle JSON")
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda _: require(False, "nonfinite lifecycle JSON"))


def names(home):
    """Names are scoped to the full canonical home, never an ambient fleet."""
    suffix = hashlib.sha256(str(home).encode()).hexdigest()[:32]
    return "fm-view-read." + suffix, "process:fm-view-read." + suffix


def schema_errors(check, filename, value):
    try:
        schema = check.Schema(str(Path(__file__).resolve().parent.parent / "docs/handoff-coverage" / filename))
        return schema.errors(value)
    except check.Unreadable as exc:
        raise ValueError("lifecycle schema unavailable: " + str(exc)) from exc


def checked_fragment(fragment):
    # The shared validator owns ALL handoff-registry/receipt grammar and rules.
    check = validator()
    problems = schema_errors(check, "handoff-registry-v1.schema.json", fragment)
    if not problems:
        problems = check.fragment_problems(fragment)
    require(not problems, "invalid lifecycle fragment: " + str(problems[:1]))
    require(fragment.get("example") is not True, "example fragment cannot cover lifecycle records")
    return check


def contract(fragment, home):
    checked_fragment(fragment)
    protocol, actor = names(home)
    selected = [item for item in fragment["protocols"] if item["id"] == protocol]
    require(len(selected) == 1, "selected home lifecycle protocol absent")
    selected = selected[0]
    require(selected["owner"] == fragment["home"] and selected["record_types"] == [SCHEMA]
            and selected["schema"] == "firstmate:bin/fm_view_lifecycle.py"
            and selected["first_stage"] == "lifecycle" and len(selected["stages"]) == 1,
            "unsupported lifecycle contract")
    stage = selected["stages"][0]
    require(stage["name"] == "lifecycle" and stage["owner"] == fragment["home"]
            and stage.get("actors") == [actor] and "writes" not in stage
            and stage["input"].get("type_field") == "schema"
            and stage["input"].get("match") == "*.json"
            and stage["input"]["reach"] == {"kind": "local"}
            and stage["outbox"]["reach"] == {"kind": "local"}, "unsupported lifecycle stage")
    require(stage["accepts"]["min"] <= VERSION <= stage["accepts"]["max"], "lifecycle reader version unsupported")
    require(set(stage["codes"]) == set(CODES)
            and all(not entry["holds_all"] for entry in stage["codes"].values()), "unsupported lifecycle refusal codes")
    state = Path(home) / "state"
    for place in (stage["input"], stage["outbox"]):
        selected_path = path(place["path"], "lifecycle place")
        require(state in selected_path.parents, "lifecycle place outside selected state root")
    return selected, stage


def candidate(home, owner, inbox, outbox, policy):
    home, _ = directory(home)
    require(type(owner) is str and HOME_ID.fullmatch(owner), "invalid home owner")
    object_fields(policy, "bounds retry_limit cleanup", "lifecycle policy")
    protocol, actor = names(home)
    fragment = {
        "format": "handoff-registry/v1", "home": owner,
        "publisher": "bin/fm-view-lifecycle.py candidate", "revision": 1,
        "published_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
        "protocols": [{
            "id": protocol, "owner": owner, "title": "Explicit read-service lifecycle decisions",
            "schema": "firstmate:bin/fm_view_lifecycle.py", "record_types": [SCHEMA],
            "versions": {"min": VERSION, "max": VERSION}, "senders": [owner], "first_stage": "lifecycle",
            "stages": [{
                "name": "lifecycle", "owner": owner, "accepts": {"min": VERSION, "max": VERSION},
                "input": {"path": str(inbox), "reach": {"kind": "local"}, "match": "*.json", "type_field": "schema"},
                "outbox": {"path": str(outbox), "reach": {"kind": "local"}},
                "bounds": policy["bounds"], "retry_limit": policy["retry_limit"],
                "codes": {code: {"fix_owner": owner, "holds_all": False, "what": what} for code, what in CODES.items()},
                "cleanup": {"action": "keep"}, "actors": [actor], "planned": True,
            }], "cleanup": policy["cleanup"],
        }],
    }
    contract(fragment, home)
    return fragment


def bundle(value):
    object_fields(value, "path identity", "selected bundle")
    selected = path(value["path"], "bundle path")
    require(type(value["identity"]) is str and DIGEST.fullmatch(value["identity"])
            and selected.name == value["identity"], "invalid bundle identity")


def owner_record(value):
    object_fields(value, "schema home roots runtime bundle epoch process socket capabilities request", "service owner")
    require(value["schema"] == OWNER_SCHEMA, "unsupported service owner version")
    home = path(value["home"], "owner home")
    object_fields(value["roots"], "home state runtime", "owner roots")
    for name, identity in value["roots"].items():
        pair(identity, "owner " + name + " identity")
    runtime = path(value["runtime"], "runtime")
    require(home / "state" in runtime.parents, "runtime outside selected state root")
    bundle(value["bundle"])
    token(value["epoch"], "owner epoch")
    object_fields(value["process"], "pid uid start_ticks boot", "process generation")
    ProcessGeneration(**value["process"])
    object_fields(value["socket"], "path identity", "bound socket")
    require(path(value["socket"]["path"], "socket path").parent == runtime, "socket outside runtime")
    pair(value["socket"]["identity"], "socket identity")
    for name in ("capabilities", "request"):
        require(type(value[name]) is str and DIGEST.fullmatch(value[name]), "invalid owner " + name + " digest")
    return value


def envelope(value, stage, home):
    require(type(value) is dict and value.get("schema") == SCHEMA
            and type(value.get("version")) is int and value["version"] >= 0, "invalid lifecycle request version")
    token(value.get("record"), "record identity")
    require(type(value.get("attempt")) is int and 1 <= value["attempt"] <= stage["retry_limit"] + 1,
            "lifecycle retry limit exceeded")
    require(value.get("home") == str(home) and value.get("owner") == stage["owner"], "lifecycle home binding mismatch")


def request_record(value, fragment, home):
    _, stage = contract(fragment, home)
    envelope(value, stage, home)
    require(value["version"] == VERSION, "version-unsupported")
    object_fields(value, "schema version record attempt home owner operation epoch roots runtime bundle workers timeout_ms expected_owner capabilities", "lifecycle request")
    require(value["operation"] in ("start", "stop"), "unsupported lifecycle operation")
    token(value["epoch"], "request epoch")
    object_fields(value["roots"], "home state runtime", "request roots")
    for name, identity in value["roots"].items():
        pair(identity, "request " + name + " identity")
    runtime = path(value["runtime"], "runtime path")
    require(Path(home) / "state" in runtime.parents, "runtime outside selected state root")
    bundle(value["bundle"])
    require(type(value["workers"]) is int and 1 <= value["workers"] <= MAX_WORKERS, "invalid worker bound")
    require(type(value["timeout_ms"]) is int and 1 <= value["timeout_ms"] <= 30000, "invalid lifecycle deadline")
    require(type(value["capabilities"]) is str and DIGEST.fullmatch(value["capabilities"]), "invalid capabilities digest")
    if value["operation"] == "start":
        require(value["expected_owner"] is None, "start must not replace an owner")
    else:
        previous = owner_record(value["expected_owner"])
        for name in ("home", "epoch", "roots", "runtime", "bundle", "capabilities"):
            require(previous[name] == value[name], "stop owner binding mismatch: " + name)
    return value


def receipt(request, fragment, home, state, seq, code=None):
    protocol, stage = contract(fragment, home)
    if code == "version-unsupported":
        # An unknown version's payload is never read as a nearby version.
        envelope(request, stage, home)
        require(request["version"] != VERSION and state == "refused", "not an unsupported-version refusal")
    else:
        request_record(request, fragment, home)
    require(state in ("accepted", "refused", "done"), "unsupported lifecycle decision")
    return envelope_receipt(request, fragment, home, state, seq, code)


def envelope_receipt(request, fragment, home, state, seq, code=None):
    """Construct a decision for a previously bound identity envelope.

    The journal alone uses this for malformed intake: its record/attempt come
    from the selected filename, never a partially decoded hostile payload.
    This function still only constructs bytes; it publishes no decision.
    """
    protocol, stage = contract(fragment, home)
    envelope(request, stage, home)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    raw = packed(request)
    require(len(raw) <= LIMIT, "lifecycle request exceeds byte bound")
    result = {"format": "handoff-receipt/v1", "receipt_id": os.urandom(8).hex(), "written_at": now,
              "protocol": protocol["id"], "version": request["version"], "stage": stage["name"],
              "home": stage["owner"], "record": request["record"], "attempt": request["attempt"],
              "seq": seq, "state": state,
              "ext": {stage["owner"] + ".request-sha256": hashlib.sha256(raw).hexdigest()}}
    if code is not None:
        result["code"] = code
    validate_receipt(result, protocol)
    return result


def validate_receipt(result, protocol):
    check = validator()
    problems = schema_errors(check, "handoff-receipt-v1.schema.json", result)
    if not problems:
        problems = check.receipt_problems(result, {protocol["id"]: protocol})
    require(not problems, "invalid lifecycle receipt: " + str(problems[:1]))
