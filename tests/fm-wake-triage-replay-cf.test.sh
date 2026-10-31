#!/usr/bin/env bash
# Try-only, never landed: one revert-counterfactual per guard of
# bin/fm-wake-triage-replay.py. Each mutant reverts one guard in a copy of the
# tool, runs tests/fm-wake-triage-replay.test.sh against it, and must make it
# fail; the unmutated copy must pass.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-wake-triage-replay-cf)
cat > "$T/mutants.py" <<'PYEOF'
import sys
M = {
 "join-latest": ('(best is None or row["epoch"] > best["epoch"])', 'best is None'),
 "join-stop-bound": ('if not row["epoch"] - skew <= t["epoch"]', 'if row["main"] != "unmatched" or not row["epoch"] - skew <= t["epoch"]'),
 "join-all-days": ('    match_rows(every, turns)\n    rows = [r for r in every if utc(r["epoch"])[:10] in days]', '    rows = [r for r in every if utc(r["epoch"])[:10] in days]\n    match_rows(rows, turns)'),
 "repeat-drops": ('            if best is None:\n                continue\n', '            if best is None or best["main"] != "unmatched":\n                continue\n'),
 "merge-type": ('elif STRENGTH.index(t["kind"]) > STRENGTH.index(best["main"]):', 'elif False:'),
 "merge-acted": ('            if t["acted"]:\n', '            if t["acted"] and best["main_text"] is t["text"] and not best["main_acted_at"]:\n'),
 "exact-key": ('if h == row["headline"] and (', 'if (h == row["headline"] or h.startswith(row["headline"][:200])) and ('),
 "acts-any-turn": ('                            acts.append((last, cmd))', '                            pass'),
 "acts-stuck": ('return re.search(r"fm-(send|control)\\b", cmd) is not None and names(cmd, m.group(1))', 'return False'),
 "acts-stuck-names": ('return re.search(r"fm-(send|control)\\b", cmd) is not None and names(cmd, m.group(1))', 'return re.search(r"fm-(send|control)\\b", cmd) is not None'),
 "acts-loop": ('return re.search(r"fm-loop(\\.sh|\\.py)?\\s+ack\\b", cmd) is not None and names(cmd, m.group(1))', 'return False'),
 "acts-loop-names": ('return re.search(r"fm-loop(\\.sh|\\.py)?\\s+ack\\b", cmd) is not None and names(cmd, m.group(1))', 'return re.search(r"fm-loop(\\.sh|\\.py)?\\s+ack\\b", cmd) is not None'),
 "act-lookback": ('row["epoch"] - ACT_LOOKBACK <= e <= at', 'row["epoch"] <= e <= at'),
 "act-lookback-bound": ('row["epoch"] - ACT_LOOKBACK <= e <= at', 'e <= at'),
 "act-before-pass": ('row["epoch"] - ACT_LOOKBACK <= e <= at', 'row["epoch"] - ACT_LOOKBACK <= e'),
 "turn-catch": ('except Exception as e:  # anything else', 'except KeyError as e:  # anything else'),
 "ack-after-row": ('if event == "acked" and when > row["epoch"]:', 'if False:'),
 "s-main-caused": ('if evidence == "pass" and at and not main_caused(row, {"passed_at": at}, acts):', 'if evidence == "pass" and at:'),
 "verdict-caused": ('        if caused:\n', '        if False:\n'),
 "verdict-untimed": ('        if untimed:\n', '        if False:\n'),
 "verdict-missing": ('        if missing:\n', '        if False:\n'),
 "verdict-duplicate": ('if len(got) != len(set(got)):', 'if False:'),
 "verdict-route": ('        if bad_route:\n', '        if False:\n'),
 "evidence-disagree": ('if len(seen) > 1:', 'if False:'),
 "score-stray-line": ('raise Refused("replay file %s has a line that is not', 'continue\n                raise Refused("replay file %s has a line that is not'),
 "score-not-main-row": ('if d["seq"] not in by_seq:\n                raise', 'if d["seq"] not in by_seq:\n                continue\n                raise'),
 "out-stray-line": ('raise Refused("existing --out %s has a line that is not', 'continue\n                raise Refused("existing --out %s has a line that is not'),
 "out-folder": ('if not os.path.isdir(os.path.dirname(out)):', 'if False:'),
 "day-format": ('    except ValueError:\n        raise Refused("--day must', '    except KeyError:\n        raise Refused("--day must'),
 "never-decision-span": ('{"decision-span", "signal",', '{"signal",'),
 "never-signal": ('"decision-span", "signal", "unrecognized",', '"decision-span", "unrecognized",'),
 "never-unrecognized": ('"signal", "unrecognized", "check:mem-guard"', '"signal", "check:mem-guard"'),
 "never-mem-guard": ('"unrecognized", "check:mem-guard", "check:claude-update"', '"unrecognized", "check:claude-update"'),
 "never-claude-update": ('"check:mem-guard", "check:claude-update",', '"check:mem-guard",'),
 "never-disk-room": ('"check:disk-room", "check:landed-sync"', '"check:landed-sync"'),
 "never-landed-sync": ('"check:landed-sync", "check:merge"', '"check:merge"'),
 "never-merge": ('"check:landed-sync", "check:merge"}', '"check:landed-sync"}'),
 "never-auth": ('re.compile(r"auth|credential|login")', 're.compile(r"credential|login")'),
 "never-credential": ('re.compile(r"auth|credential|login")', 're.compile(r"auth|login")'),
 "never-login": ('re.compile(r"auth|credential|login")', 're.compile(r"auth|credential")'),
 "claude-nojson": ('return "", 0.0, "claude rc=%d gave no JSON result', 'raise\n            return "", 0.0, "claude rc=%d gave no JSON result'),
 "shape-catch": ('except (AttributeError, TypeError, ValueError, KeyError) as e:', 'except KeyError as e:'),
 "claude-not-object": ('        if not isinstance(d, dict):\n            raise TypeError', '        if False:\n            raise TypeError'),
 "claude-rc": ('if p.returncode != 0 or d.get("is_error"):', 'if d.get("is_error"):'),
 "claude-is-error": ('if p.returncode != 0 or d.get("is_error"):', 'if p.returncode != 0:'),
 "claude-num-turns": ('if str(d.get("num_turns", 1)) != "1":', 'if False:'),
 "claude-cost-float": ('cost = float(d.get("total_cost_usd") or 0)', 'cost = d.get("total_cost_usd") or 0'),
 "pi-no-end": ('    if end is None:\n', '    if False:\n'),
 "pi-not-objects": ('if not isinstance(messages, list) or not all(isinstance(m, dict) for m in messages):', 'if False:'),
 "pi-no-assistant": ('    if not msgs:\n', '    if False:\n'),
 "pi-stop-error": ('last.get("stopReason") in ("error", "aborted")', 'False'),
 "pi-tool-result": ('m.get("role") == "toolResult" or ', ''),
 "pi-tool-call": ('b.get("type") == "toolCall"', 'False'),
 "pi-cost-float": ('cost = float(((last.get("usage") or {}).get("cost") or {}).get("total") or 0)', 'cost = ((last.get("usage") or {}).get("cost") or {}).get("total") or 0'),
 "answer-action": ('m.group(2) in ("settle", "relay")', 'True'),
 "resume-audit-error": ('if d.get("error") or d.get("audit", "").startswith("error:"):', 'if d.get("error"):'),
 "fingerprint-effort": ('json.dumps([model_tag, args.effort, prompt_sha,', 'json.dumps([model_tag, prompt_sha,'),
 "fingerprint-skill": ('json.dumps([model_tag, args.effort, prompt_sha,', 'json.dumps([model_tag, args.effort,'),
 "fingerprint-audit": ('args.audit_fast_relay, log.first]', 'log.first]'),
}
if sys.argv[1] == "list":
    print("\n".join(M))
    sys.exit(0)
name, path = sys.argv[1], sys.argv[2]
old, new = M[name]
s = open(path).read()
if s.count(old) != 1:
    print("mutant %s matches %d place(s)" % (name, s.count(old)))
    sys.exit(3)
open(path, "w").write(s.replace(old, new))
PYEOF
run_one() {  # <name|base>: prints "<name> <rc> <first FAIL line>"
  local name=$1 d="$T/$1" rc
  mkdir -p "$d/bin" "$d/.agents/skills/wake-triage"
  cp "$ROOT/bin/fm-wake-triage-replay.sh" "$ROOT/bin/fm-wake-triage-replay.py" "$d/bin/"
  cp "$ROOT/.agents/skills/wake-triage/SKILL.md" "$d/.agents/skills/wake-triage/"
  if [ "$name" != base ]; then
    python3 "$T/mutants.py" "$name" "$d/bin/fm-wake-triage-replay.py" > "$d/apply" 2>&1 || { echo "$name apply-failed $(cat "$d/apply")"; return; }
  fi
  rc=0
  FM_CF_TR="$d/bin/fm-wake-triage-replay.sh" bash "$ROOT/tests/fm-wake-triage-replay.test.sh" > "$d/out" 2>&1 || rc=$?
  echo "$name $rc $(grep -m1 'not ok' "$d/out" | cut -c1-200)"
}
export -f run_one
export T ROOT
python3 "$T/mutants.py" list > "$T/names"
{ echo base; cat "$T/names"; } | xargs -P 4 -I{} bash -c 'run_one {}' > "$T/results"
sort "$T/results"
bad=0
while read -r name rc rest; do
  if [ "$name" = base ]; then
    [ "$rc" = 0 ] || { echo "BASE FAILED: $rest"; sed -n '1,80p' "$T/base/out"; bad=1; }
  elif [ "$rc" = 0 ] || [ "$rc" = apply-failed ]; then
    echo "MUTANT SURVIVED: $name $rc $rest"
    bad=1
  fi
done < "$T/results"
[ "$bad" = 0 ] || fail "a counterfactual did not fail, or the base did not pass"
pass "every guard's revert fails tests/fm-wake-triage-replay.test.sh, and the base passes"
