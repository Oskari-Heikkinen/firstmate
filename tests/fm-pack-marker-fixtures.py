#!/usr/bin/env python3
"""Test-owned marker corruption and transaction writers; no production imports.

Called only by fm-pack.test.sh in its private fixture directory. The mutation
names identify independent refusal rules, not alternative production parsers.
"""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import time


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value) + "\n")


def transaction(case, root, source):
    base = root / "pack"
    marker = base / "pkg.marker.json"
    members = base / "pkg.members.sha256"
    receipt = base / "pkg.verify.json"
    if case in ("rebind", "reviewer"):
        (source / "sub/file with space").write_text("other")
        members.write_text(members.read_text().replace(sha(b"hello"), sha(b"other")))
        m = json.loads(marker.read_text())
        m["members_sha256"] = sha(members.read_bytes())
        save(marker, m)
        if case == "rebind":
            r = json.loads(receipt.read_text())
            r["marker_sha256"] = sha(marker.read_bytes())
            r["members_sha256"] = sha(members.read_bytes())
            save(receipt, r)  # Same timestamp and image digest, new authority.
    elif case == "source-pointer":
        other = root / "different/pkg"
        shutil.copytree(source, other)
        m = json.loads(marker.read_text())
        m["source"] = str(other)
        save(marker, m)
        r = json.loads(receipt.read_text())
        r["marker_sha256"] = sha(marker.read_bytes())
        save(receipt, r)
    elif case == "receipt-time":
        r = json.loads(receipt.read_text())
        r["verified_at"] -= 1
        save(receipt, r)
    elif case.endswith("-missing"):
        (base / ("pkg." + case[:-8])).unlink()
    elif case.endswith("-replace"):
        path = base / ("pkg." + case[:-8])
        new = path.with_name(path.name + ".new")
        new.write_bytes(path.read_bytes())
        os.replace(new, path)  # Same bytes/time value, different inode.
    elif case == "image-write":
        with (base / "pkg.sqfs").open("ab") as stream:
            stream.write(b"x")
    else:
        raise ValueError(case)
    save(root / "record-stamp.json", record_stamp(receipt))


def record_stamp(path):
    if not path.exists():
        return None
    st = path.stat()
    return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, sha(path.read_bytes())]


def mutate(case, root):
    base = root / "pack"
    marker = base / "pkg.marker.json"
    members = base / "pkg.members.sha256"
    tree = base / "pkg.tree.tsv"
    receipt = base / "pkg.verify.json"
    m = json.loads(marker.read_text())
    diagnostic = None
    if case.startswith("time-"):
        values = {"zero": 0, "negative": -1, "future": int(time.time()) + 86400,
                  "boolean": True, "string": "1", "large": 2**63}
        r = json.loads(receipt.read_text())
        r["verified_at"] = values[case[5:]]
        save(receipt, r)
        return "invalid verification time"
    fields = {
        "pkg-type": ("pkg", [], "invalid marker pkg"),
        "pkg-name": ("pkg", "../pkg", "invalid marker pkg"),
        "pkg-binding": ("pkg", "other", "invalid marker pkg"),
        "task-type": ("task", [], "invalid marker task"),
        "task-name": ("task", "job/sub", "invalid marker task"),
        "source-type": ("source", [], "invalid marker source"),
        "source-relative": ("source", "source/pkg", "invalid marker source"),
        "source-traversal": ("source", "/source/../pkg", "invalid marker source"),
        "source-name": ("source", "/source/other", "invalid marker source"),
        "date-type": ("created", [], "invalid marker created"),
        "date-value": ("created", "not-a-date", "does not match format"),
        "census-files": ("files", 3, "marker census mismatch"),
        "census-entries": ("entries", 5, "marker census mismatch"),
        "census-bytes": ("bytes", 6, "marker census mismatch"),
    }
    if case in fields:
        key, value, diagnostic = fields[case]
        m[key] = value
    elif case.startswith("integer-"):
        key, value = case[8:].split("-", 1)
        m[key] = {"negative": -1, "boolean": True, "large": 2**63, "string": "1"}[value]
        diagnostic = "invalid marker " + key
    elif case in ("record-extra", "record-version"):
        r = json.loads(receipt.read_text())
        if case == "record-extra":
            r["extra"] = True
            diagnostic = "unknown or missing JSON field"
        else:
            r["format"] = "fm-pack-marker-verification/v9"
            diagnostic = "verification record digest mismatch"
        save(receipt, r)
        return diagnostic
    elif case == "object-shape":
        m["extra"] = True
        diagnostic = "unknown or missing JSON field"
    elif case == "duplicate-key":
        marker.write_text('{"schema":"tj-pack-marker/v1",' + marker.read_text()[1:])
        return "duplicate JSON key: schema"
    elif case == "byte-bound":
        with marker.open("ab") as stream:
            stream.truncate(65537)
        return "input size exceeds byte bound"
    elif case == "readable-regular":
        marker.unlink()
        os.mkfifo(marker)
        return "not a readable regular file"
    elif case == "nofollow":
        target = marker.with_suffix(".saved")
        marker.rename(target)
        marker.symlink_to(target)
        return "symbolic links"
    elif case == "partial-line":
        members.write_bytes(members.read_bytes()[:-1])
        diagnostic = "partial manifest last line"
    elif case == "nul":
        members.write_bytes(members.read_bytes() + b"\x00\n")
        diagnostic = "NUL in manifest"
    elif case == "entry-bound":
        members.write_bytes(b"\n" * 2000002)
        diagnostic = "too many manifest entries"
    elif case == "duplicate-member":
        members.write_text(members.read_text() + members.read_text().splitlines()[0] + "\n")
        diagnostic = "duplicate member: empty"
    elif case == "tree-row":
        tree.write_text(tree.read_text().replace("f\t0\t644\t-\tempty", "f\t0\t644\t-\tempty\textra"))
        diagnostic = "malformed tree.tsv row"
    elif case == "tree-field":
        tree.write_text(tree.read_text().replace("f\t0\t644", "x\t0\t644"))
        diagnostic = "malformed tree.tsv field"
    elif case in ("tree-size", "tree-large"):
        old, new = (("l\t0\t777", "l\t1\t777") if case == "tree-size"
                    else ("f\t5\t644", "f\t" + str(2**63) + "\t644"))
        tree.write_text(tree.read_text().replace(old, new))
        diagnostic = "invalid tree size"
    elif case == "tree-link":
        tree.write_text(tree.read_text().replace("f\t0\t644\t-", "f\t0\t644\tbad"))
        diagnostic = "invalid tree link"
    elif case == "duplicate-tree":
        tree.write_text(tree.read_text() + tree.read_text().splitlines()[1] + "\n")
        diagnostic = "duplicate tree entry: empty"
    elif case in ("ancestor", "ancestor-kind"):
        replacement = "" if case == "ancestor" else "l\t0\t777\ttarget\tsub\n"
        tree.write_text(tree.read_text().replace("d\t0\t755\t-\tsub\n", replacement))
        m["entries"] = 3 if case == "ancestor" else 4
        diagnostic = "missing/non-directory ancestor"
    elif case == "member-names":
        members.write_text(members.read_text().replace("  empty\n", "  other\n"))
        diagnostic = "tree/member name mismatch"
    elif case == "image-record":
        (base / "pkg.sqfs.sha256").write_text("not a digest\n")
        diagnostic = "malformed sqfs.sha256"
    elif case == "collision":
        save(base / "pkg.json", {"format": "fm-pack-unit/v1", "dir": "pkg"})
        diagnostic = "ambiguous unit metadata"
    elif case == "restore":
        diagnostic = "restore does not support tj-pack-marker/v1"
    elif case == "source-root":
        source = root / "source/pkg"
        source.rename(root / "source/saved")
        source.symlink_to(root / "source/saved", target_is_directory=True)
        diagnostic = "not a real tree directory"
    elif case == "source-extra":
        (root / "source/pkg/z-extra").write_text("extra")
        diagnostic = "unexpected tree entry:"
    elif case == "source-kind":
        path = root / "source/pkg/empty"
        path.unlink()
        os.mkfifo(path)
        diagnostic = "unsupported tree kind: empty"
    else:
        raise ValueError(case)
    m["members_sha256"] = sha(members.read_bytes())
    m["tree_sha256"] = sha(tree.read_bytes())
    save(marker, m)
    return diagnostic


def tool(case, args):
    """Alter only the public unsquashfs protocol, never the adapter itself."""
    if args[0] != "-lln":
        if case == "cat-failed":
            return 7
        return subprocess.call([os.environ["PACK_REAL_UNSQUASHFS"], *args])
    if case == "tool-failed":
        return 7
    if case == "tool-bound":
        for _ in range(256):
            sys.stdout.buffer.write(b"x" * (1 << 20))
        sys.stdout.buffer.write(b"\n")
        return 0
    raw = subprocess.check_output([os.environ["PACK_REAL_UNSQUASHFS"], *args], text=True)
    rows = raw.splitlines()
    if case == "listing":
        rows.append("not a listing")
    elif case == "image-link":
        rows = [line.replace(" -> sub/file with space", " -> x -> y") for line in rows]
    elif case == "embedded-entry":
        rows = [("d" + line[1:]) if line.endswith("squashfs-root/.tj-pack.json") else line for line in rows]
    elif case == "root-entry":
        rows.append(next(line for line in rows if line.endswith(" squashfs-root")))
    elif case == "prefix":
        rows = [line.replace("squashfs-root/pkg/empty", "squashfs-root/xxx/empty") for line in rows]
    elif case == "image-entry":
        rows.append(next(line for line in rows if line.endswith("squashfs-root/pkg/empty")))
    elif case == "root-missing":
        rows = [line for line in rows if not line.endswith("squashfs-root/pkg")]
    elif case == "permission":
        rows = [(line[:3] + "r" + line[4:]) if line.endswith("squashfs-root/pkg/empty") else line for line in rows]
    elif case != "cat-failed":
        raise ValueError(case)
    print("\n".join(rows))
    return 0


if __name__ == "__main__":
    action, case, directory, *args = sys.argv[1:]
    root = Path(directory)
    if action == "transaction":
        transaction(case, root, Path(args[0]))
    elif action == "mutate":
        print(mutate(case, root))
    elif action == "tool":
        sys.exit(tool(case, args))
    elif action == "receipt-check":
        expected = json.loads((root / "record-stamp.json").read_text())
        sys.exit(0 if record_stamp(root / "pack/pkg.verify.json") == expected else 1)
    elif action == "capture":
        response = json.load(sys.stdin)
        if case != "failed":
            del response[case]
        print(json.dumps(response))
        sys.exit(7 if case == "failed" else 0)
    else:
        raise ValueError(action)
