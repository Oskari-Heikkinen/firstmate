#!/usr/bin/env python3
"""fm-handoff-validate.py - validate handoff-coverage/v1 fragments and receipts.

Usage:
  fm-handoff-validate.py [--schema-dir DIR] fragment FILE...
  fm-handoff-validate.py [--schema-dir DIR] receipt [--fragment FILE]... FILE...
  fm-handoff-validate.py [--schema-dir DIR] outbox [--fragment FILE]... DIR

docs/handoff-coverage.md owns the formats; the JSON schemas beside it in
docs/handoff-coverage/ are their machine-checkable form. This tool reads files
and writes nothing, so publishers, stage adapters, conformance fixtures and the
watcher can all run it before trusting a file.

fragment  checks each handoff-registry/v1 fragment against its schema and the
          cross-field rules: a protocol is owned by the publishing home, names
          are unique, first_stage and the cleanup stage exist, ranges are
          ordered, every stage's writes range is accepted by the next stage
          (readers first), a reserved code is never redeclared, and no outbox
          is also an input place, except at a stage a receipt adapter reads.
          Several fragments in one call must not declare the same protocol id.
receipt   checks each handoff-receipt/v1 file against its schema and the
          cross-field rules (a waiting receipt's until is after written_at).
          With --fragment, it also checks the receipt against the registry:
          the protocol and stage exist, the writer is the stage owner, the
          version is accepted (or the code is version-unsupported), the code is
          declared or reserved, holds_all agrees with the code, and a wait
          ends within the stage's waiting bound.
outbox    checks every receipt in DIR as receipt does, plus the file name rule
          <written_at as YYYYMMDDTHHMMSS.ffffffZ>-<receipt_id>.json. Dot entries
          (the .tmp/ staging folder, a .synced-at stamp) are skipped; any other
          entry that is not a receipt name is a finding.

Output: one "ok <kind> <path>" line per valid file, one "<path>: <where>:
<problem>" line per finding, then one summary line.

Exit: 0 every file valid; 1 findings; 2 usage; 3 an input or schema could not
be read, or a schema uses a keyword this validator does not implement (unknown
is failure, never a pass).
"""

import datetime
import json
import os
import re
import sys

PROG = "fm-handoff-validate"
OK, FINDINGS, USAGE, UNREADABLE = 0, 1, 2, 3
REGISTRY_FORMAT = "handoff-registry/v1"
RECEIPT_FORMAT = "handoff-receipt/v1"
RESERVED_CODES = ("version-unsupported",)
RECEIPT_NAME_RE = re.compile(r"^([0-9]{8}T[0-9]{6}\.[0-9]{6}Z)-([0-9a-f]{16})\.json$")
DURATION_RE = re.compile(r"^([1-9][0-9]*)([smhd])$")
DURATION_UNIT = {"s": 1, "m": 60, "h": 3600, "d": 86400}


class Unreadable(Exception):
    pass


# ---------- schema subset ----------

# The shipped schemas use only these keywords. Any other keyword refuses the
# schema, so a schema edit cannot silently stop being enforced here.
ANNOTATIONS = {"$schema", "$id", "$comment", "title", "description", "$defs"}
KEYWORDS = ANNOTATIONS | {
    "$ref", "type", "properties", "required", "additionalProperties", "propertyNames",
    "enum", "const", "pattern", "minLength", "maxLength", "minimum", "maximum",
    "items", "minItems", "uniqueItems", "allOf", "if", "then", "else", "not",
}
JSON_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


class Schema:
    def __init__(self, path):
        self.path = path
        try:
            with open(path, encoding="utf-8") as handle:
                self.root = json.load(handle)
        except (OSError, ValueError) as exc:
            raise Unreadable(f"schema {path}: {exc}") from exc
        self.audit(self.root, "#")

    def audit(self, node, where):
        if isinstance(node, bool):
            return
        if not isinstance(node, dict):
            raise Unreadable(f"schema {self.path}: {where} is not a schema")
        unknown = sorted(set(node) - KEYWORDS)
        if unknown:
            raise Unreadable(f"schema {self.path}: {where} uses unsupported keyword {unknown[0]}")
        for key in ("properties", "$defs"):
            for name, sub in node.get(key, {}).items():
                self.audit(sub, f"{where}/{key}/{name}")
        for key in ("additionalProperties", "propertyNames", "items", "if", "then", "else", "not"):
            if key in node:
                self.audit(node[key], f"{where}/{key}")
        for index, sub in enumerate(node.get("allOf", [])):
            self.audit(sub, f"{where}/allOf/{index}")

    def resolve(self, ref):
        if not ref.startswith("#/"):
            raise Unreadable(f"schema {self.path}: only local $ref is supported, not {ref}")
        node = self.root
        for part in ref[2:].split("/"):
            if not isinstance(node, dict) or part not in node:
                raise Unreadable(f"schema {self.path}: unresolved $ref {ref}")
            node = node[part]
        return node

    def errors(self, value, node=None, where=""):
        if node is None:
            node = self.root
        out = []
        self.check(value, node, where, out)
        return out

    def check(self, value, node, where, out):
        here = where or "/"
        if node is True:
            return
        if node is False:
            out.append((here, "is not allowed here"))
            return
        if "$ref" in node:
            self.check(value, self.resolve(node["$ref"]), where, out)
        if "type" in node:
            types = node["type"] if isinstance(node["type"], list) else [node["type"]]
            if not any(JSON_TYPES[t](value) for t in types):
                out.append((here, f"must be {' or '.join(types)}"))
                return
        if "const" in node and value != node["const"]:
            out.append((here, f"must be {json.dumps(node['const'])}"))
        if "enum" in node and value not in node["enum"]:
            out.append((here, "must be one of " + ", ".join(json.dumps(v) for v in node["enum"])))
        if isinstance(value, str):
            if "minLength" in node and len(value) < node["minLength"]:
                out.append((here, f"must be at least {node['minLength']} characters"))
            if "maxLength" in node and len(value) > node["maxLength"]:
                out.append((here, f"must be at most {node['maxLength']} characters"))
            if "pattern" in node and not re.search(node["pattern"], value):
                out.append((here, f"{json.dumps(value)} does not match {node['pattern']}"))
        if JSON_TYPES["number"](value):
            if "minimum" in node and value < node["minimum"]:
                out.append((here, f"must be at least {node['minimum']}"))
            if "maximum" in node and value > node["maximum"]:
                out.append((here, f"must be at most {node['maximum']}"))
        if isinstance(value, list):
            if "minItems" in node and len(value) < node["minItems"]:
                out.append((here, f"must have at least {node['minItems']} items"))
            if node.get("uniqueItems"):
                seen = []
                for item in value:
                    if item in seen:
                        out.append((here, f"repeats {json.dumps(item)}"))
                        break
                    seen.append(item)
            if "items" in node:
                for index, item in enumerate(value):
                    self.check(item, node["items"], f"{where}/{index}", out)
        if isinstance(value, dict):
            for name in node.get("required", []):
                if name not in value:
                    out.append((here, f"missing required field {name}"))
            props = node.get("properties", {})
            for name, item in value.items():
                if "propertyNames" in node:
                    self.check(name, node["propertyNames"], f"{where}/{name}", out)
                if name in props:
                    self.check(item, props[name], f"{where}/{name}", out)
                elif "additionalProperties" in node:
                    if node["additionalProperties"] is False:
                        out.append((f"{where}/{name}", "is not a field of this format (extensions go in ext)"))
                    else:
                        self.check(item, node["additionalProperties"], f"{where}/{name}", out)
        for sub in node.get("allOf", []):
            self.check(value, sub, where, out)
        if "if" in node:
            if not self.errors(value, node["if"], where):
                if "then" in node:
                    self.check(value, node["then"], where, out)
            elif "else" in node:
                self.check(value, node["else"], where, out)
        if "not" in node and not self.errors(value, node["not"], where):
            out.append((here, "matches a shape that is not allowed"))


# ---------- helpers ----------

def parse_utc(text):
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.datetime.strptime(text, fmt).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
    return None


def seconds(duration):
    match = DURATION_RE.match(duration or "")
    return int(match.group(1)) * DURATION_UNIT[match.group(2)] if match else None


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise Unreadable(f"{path}: {exc.strerror or exc}") from exc
    try:
        return json.loads(text), None
    except ValueError as exc:
        return None, f"not valid JSON ({exc})"


def code_entry(stage, code):
    codes = stage.get("codes", {})
    if code in codes:
        return codes[code]
    best = None
    for key, entry in codes.items():
        if key.endswith("*") and code.startswith(key[:-1]) and (best is None or len(key) > len(best[0])):
            best = (key, entry)
    return best[1] if best else None


# ---------- cross-field rules ----------

def fragment_problems(doc):
    out = []
    home = doc.get("home")
    seen_ids = set()
    inputs = {}
    outboxes = []
    for pindex, proto in enumerate(doc.get("protocols", [])):
        pw = f"/protocols/{pindex}"
        pid = proto.get("id")
        if pid in seen_ids:
            out.append((pw + "/id", f"protocol {pid} is declared twice"))
        seen_ids.add(pid)
        if proto.get("owner") != home:
            out.append((pw + "/owner", f"a fragment declares only protocols its home owns; {proto.get('owner')} is not {home}"))
        versions = proto.get("versions", {})
        if versions.get("min", 0) > versions.get("max", 0):
            out.append((pw + "/versions", "min is greater than max"))
        stages = proto.get("stages", [])
        names = [stage.get("name") for stage in stages]
        for index, name in enumerate(names):
            if name in names[:index]:
                out.append((f"{pw}/stages/{index}/name", f"stage {name} is declared twice"))
        if proto.get("first_stage") not in names:
            out.append((pw + "/first_stage", f"{proto.get('first_stage')} is not a stage of {pid}"))
        if proto.get("cleanup", {}).get("stage") not in names:
            out.append((pw + "/cleanup/stage", f"{proto.get('cleanup', {}).get('stage')} is not a stage of {pid}"))
        rule_ids = [rule.get("id") for rule in proto.get("dated_rules", [])]
        for index, rule_id in enumerate(rule_ids):
            if rule_id in rule_ids[:index]:
                out.append((f"{pw}/dated_rules/{index}/id", f"dated rule {rule_id} is declared twice"))
        for sindex, stage in enumerate(stages):
            sw = f"{pw}/stages/{sindex}"
            for key in ("accepts", "writes"):
                rng = stage.get(key)
                if rng and rng.get("min", 0) > rng.get("max", 0):
                    out.append((f"{sw}/{key}", "min is greater than max"))
            writes = stage.get("writes")
            if writes and (writes.get("min", 0) < versions.get("min", 0) or writes.get("max", 0) > versions.get("max", 0)):
                out.append((f"{sw}/writes", f"writes versions outside the protocol's versions {versions.get('min')}..{versions.get('max')}"))
            if writes and sindex + 1 < len(stages):
                nxt = stages[sindex + 1]
                accepts = nxt.get("accepts", {})
                if writes.get("min", 0) < accepts.get("min", 0) or writes.get("max", 0) > accepts.get("max", 0):
                    out.append((f"{sw}/writes", f"writes {writes.get('min')}..{writes.get('max')} but the next stage "
                                f"{nxt.get('name')} accepts only {accepts.get('min')}..{accepts.get('max')} (readers first)"))
            for code in stage.get("codes", {}):
                if code.rstrip("*") in RESERVED_CODES or (code.endswith("*") and any(r.startswith(code[:-1]) for r in RESERVED_CODES)):
                    out.append((f"{sw}/codes/{code}", "a reserved code is routed by the protocol and is never declared"))
            if "input" in stage:
                inputs.setdefault(stage["input"].get("path"), f"{sw}/input")
            # A receipt adapter reads existing records rather than an outbox of receipt
            # files, so its outbox may be the input folder those records sit in.
            adapted = f"{stage.get('owner')}.receipt-adapter" in (stage.get("ext") or {})
            if "outbox" in stage and not adapted:
                outboxes.append((stage["outbox"].get("path"), f"{sw}/outbox"))
    for path, where in outboxes:
        if path in inputs:
            out.append((where + "/path", f"{path} is also the input place at {inputs[path]}; receipts need their own folder"))
    return out


def receipt_problems(doc, protocols):
    out = []
    written = parse_utc(doc.get("written_at", ""))
    until = parse_utc(doc.get("until", "")) if "until" in doc else None
    if doc.get("state") == "waiting" and written and until and until <= written:
        out.append(("/until", "must be after written_at"))
    if protocols is None:
        return out
    proto = protocols.get(doc.get("protocol"))
    if proto is None:
        out.append(("/protocol", f"{doc.get('protocol')} is not declared by any given fragment"))
        return out
    stage = next((s for s in proto.get("stages", []) if s.get("name") == doc.get("stage")), None)
    if stage is None:
        out.append(("/stage", f"{doc.get('stage')} is not a stage of {proto.get('id')}"))
        return out
    if doc.get("home") != stage.get("owner"):
        out.append(("/home", f"stage {stage.get('name')} is owned by {stage.get('owner')}, not {doc.get('home')}"))
    accepts = stage.get("accepts", {})
    version = doc.get("version")
    code = doc.get("code")
    if isinstance(version, int) and not accepts.get("min", 0) <= version <= accepts.get("max", 0) \
            and not (doc.get("state") == "refused" and code == "version-unsupported"):
        out.append(("/version", f"stage {stage.get('name')} accepts {accepts.get('min')}..{accepts.get('max')}; "
                    "an unaccepted version is refused with code version-unsupported"))
    if code is not None and code not in RESERVED_CODES:
        entry = code_entry(stage, code)
        if entry is None:
            out.append(("/code", f"{code} is not declared for stage {stage.get('name')}"))
        elif bool(entry.get("holds_all")) != bool(doc.get("holds_all")):
            out.append(("/holds_all", f"must be {str(bool(entry.get('holds_all'))).lower()} as the registry declares for {code}"))
    if doc.get("state") == "waiting" and written and until:
        bound = seconds(stage.get("bounds", {}).get("waiting"))
        if bound is not None and (until - written).total_seconds() > bound:
            out.append(("/until", f"waits past the stage's waiting bound {stage['bounds']['waiting']}"))
    return out


# ---------- commands ----------

class Run:
    def __init__(self):
        self.files = 0
        self.findings = 0

    def report(self, path, problems, kind):
        self.files += 1
        if problems:
            for where, problem in problems:
                print(f"{path}: {where}: {problem}")
            self.findings += len(problems)
        else:
            print(f"ok {kind} {path}")


def validate_fragments(schema, paths, run):
    """Validate fragments; return {protocol id: protocol} from the valid ones."""
    protocols = {}
    owners = {}
    for path in paths:
        doc, bad = load_json(path)
        problems = [("/", bad)] if bad else schema.errors(doc)
        if not problems:
            problems = fragment_problems(doc)
        if not problems:
            for index, proto in enumerate(doc.get("protocols", [])):
                if proto["id"] in owners:
                    problems.append((f"/protocols/{index}/id", f"protocol {proto['id']} is also declared in {owners[proto['id']]}"))
                else:
                    owners[proto["id"]] = path
                    protocols[proto["id"]] = proto
        run.report(path, problems, "fragment")
    return protocols


def validate_receipt(schema, path, protocols, run, name_check):
    doc, bad = load_json(path)
    problems = [("/", bad)] if bad else schema.errors(doc)
    if not problems:
        problems = receipt_problems(doc, protocols)
    if not problems and name_check:
        match = RECEIPT_NAME_RE.match(os.path.basename(path))
        stamp = doc["written_at"].replace("-", "").replace(":", "")
        if not match or match.group(1) != stamp or match.group(2) != doc["receipt_id"]:
            problems.append(("/", f"file name must be {stamp}-{doc['receipt_id']}.json"))
    run.report(path, problems, "receipt")


def parse_args(argv):
    schema_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "handoff-coverage")
    if argv[:1] == ["--schema-dir"]:
        if len(argv) < 2:
            raise ValueError("--schema-dir needs a directory")
        schema_dir, argv = argv[1], argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        raise ValueError(None)
    command, rest = argv[0], argv[1:]
    if command not in ("fragment", "receipt", "outbox"):
        raise ValueError(f"unknown command {command}")
    fragments = []
    while command != "fragment" and rest[:1] == ["--fragment"]:
        if len(rest) < 2:
            raise ValueError("--fragment needs a file")
        fragments.append(rest[1])
        rest = rest[2:]
    if not rest or (command == "outbox" and len(rest) != 1):
        raise ValueError(f"{command} needs {'one directory' if command == 'outbox' else 'at least one file'}")
    return schema_dir, command, fragments, rest


def usage(message):
    if message:
        print(f"{PROG}: {message}", file=sys.stderr)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return USAGE


def main(argv):
    try:
        schema_dir, command, fragments, targets = parse_args(argv)
    except ValueError as exc:
        return usage(exc.args[0])
    run = Run()
    try:
        registry = Schema(os.path.join(schema_dir, "handoff-registry-v1.schema.json"))
        if command == "fragment":
            validate_fragments(registry, targets, run)
        else:
            receipt = Schema(os.path.join(schema_dir, "handoff-receipt-v1.schema.json"))
            protocols = None
            if fragments:
                given = Run()
                protocols = validate_fragments(registry, fragments, given)
                if given.findings:
                    run.findings += given.findings
                    run.files += given.files
            if command == "receipt":
                for path in targets:
                    validate_receipt(receipt, path, protocols, run, False)
            else:
                folder = targets[0]
                try:
                    entries = sorted(os.listdir(folder))
                except OSError as exc:
                    raise Unreadable(f"{folder}: {exc.strerror or exc}") from exc
                for entry in entries:
                    if entry.startswith("."):
                        continue
                    path = os.path.join(folder, entry)
                    if not RECEIPT_NAME_RE.match(entry) or not os.path.isfile(path):
                        run.report(path, [("/", "not a receipt file name; an outbox holds only receipts")], "receipt")
                        continue
                    validate_receipt(receipt, path, protocols, run, True)
    except Unreadable as exc:
        print(f"{PROG}: unreadable: {exc}")
        return UNREADABLE
    if run.findings:
        print(f"{PROG}: findings={run.findings} files={run.files}")
        return FINDINGS
    print(f"{PROG}: ok files={run.files}")
    return OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
