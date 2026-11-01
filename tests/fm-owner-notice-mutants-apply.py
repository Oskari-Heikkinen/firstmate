"""usage: python3 apply.py <spec.json> <mutant-id> <copy-root>: apply one mutant's edits in place."""
import json, sys
spec, mid, root = sys.argv[1:4]
m = [x for x in json.load(open(spec)) if x["id"] == mid][0]
for f, old, new in m["edits"]:
    p = root + "/" + f
    t = open(p).read()
    if t.count(old) != 1:
        sys.exit("bad edit in %s %s" % (mid, f))
    open(p, "w").write(t.replace(old, new))
print(m["case"])
