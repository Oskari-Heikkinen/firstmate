#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the user-level data gate (docs/data-gate.md).
#
# bin/fm-data-gate-policy.mjs owns the decision and bin/fm-data-gate.sh is the
# harness entry point. Every case runs against a fake HOME holding a fake main
# home, a treehouse pool with one secondmate home and one task worktree, a bulk
# store, a ledger, and symlinks, so nothing here reads or writes the real ~.
# The table covers every read in the data-storage plan's "Legitimate reads
# today" table as ALLOW, the protected roots as BLOCK, and the parsing edges.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-data-gate)
FAKE_HOME="$TMP_ROOT/home"
GATE="$ROOT/bin/fm-data-gate.sh"
MAIN="$FAKE_HOME/Tools/firstmate"
POOL="$FAKE_HOME/.treehouse/firstmate-abc123"
SM="$POOL/1/firstmate"
WT="$POOL/2/firstmate"

make_home_shape() {
  mkdir -p "$1/bin" "$1/data"
  : >"$1/AGENTS.md"
}

build_fixture() {
  make_home_shape "$MAIN"
  mkdir -p "$MAIN/data/task1" "$MAIN/data/rolling-runs-v11-2-1/slices/s1" \
    "$MAIN/data/tetjet-offload/results/r1" "$MAIN/data/exp2/tetjet-results/t1"
  printf 'report\n' >"$MAIN/data/task1/report.md"
  printf '{}\n' >"$MAIN/data/tetjet-offload/results/r1/receipt.json"
  printf '# bulk\nrolling-runs-*/slices/\n*/tetjet-results/\n' >"$MAIN/data/bulk-paths.txt"
  make_home_shape "$SM"
  : >"$SM/.fm-secondmate-home"
  make_home_shape "$WT"
  mkdir -p "$WT/src"
  cat >"$POOL/treehouse-state.json" <<EOF
{"worktrees":[{"name":"1","path":"$SM","leased":true},{"name":"2","path":"$WT"}]}
EOF
  mkdir -p "$FAKE_HOME/lattice-store/items/tetjet-slice/s1/fetched" "$FAKE_HOME/lattice-store/quarantine" \
    "$FAKE_HOME/lattice-ledger/runs" "$FAKE_HOME/lattice-ledger/geometry/site/ws/run" \
    "$FAKE_HOME/lattice-ledger/search-recording/r1" "$FAKE_HOME/lattice-ledger/diagnostics/d1" \
    "$FAKE_HOME/.cache/pip"
  : >"$FAKE_HOME/lattice-store/catalog.jsonl"
  : >"$FAKE_HOME/lattice-ledger/index.json"
  : >"$FAKE_HOME/lattice-ledger/runs/E1.md"
  : >"$FAKE_HOME/lattice-ledger/geometry/site/ws/run/x.json"
  ln -s "$FAKE_HOME/lattice-store" "$FAKE_HOME/link-store"
  ln -s "$MAIN/data" "$FAKE_HOME/data-link"
  ln -s "$MAIN" "$FAKE_HOME/fm-link"
}

cwd_of() {
  case "$1" in
    H) printf '%s\n' "$MAIN" ;;
    T) printf '%s\n' "$MAIN/data/task1" ;;
    S) printf '%s\n' "$SM" ;;
    W) printf '%s\n' "$WT" ;;
    '~') printf '%s\n' "$FAKE_HOME" ;;
    L) printf '%s\n' "$FAKE_HOME/fm-link" ;;
    *) fail "unknown cwd key $1" ;;
  esac
}

gate() {  # <mode> <args...>
  local mode=$1
  shift
  HOME="$FAKE_HOME" LATTICE_DATA_GATE="$mode" "$GATE" "$@"
}

# expect | cwd | bash command
BASH_TABLE=$(cat <<'EOF'
# --- Legitimate reads today (report section 4), each must stay allowed ---
allow|H|python3 -m lattice_batches request-collected R1
allow|H|cat ~/lattice-ledger/index.json
allow|H|head -c 8192 ~/lattice-ledger/runs/E1.md
allow|H|ls ~/lattice-ledger/geometry/site/ws/run/
allow|H|cat ~/lattice-ledger/geometry/site/ws/run/x.json
allow|H|cat data/tetjet-offload/results/r1/receipt.json
allow|H|python3 -m lattice_batches report-due --receipts data/tetjet-offload/results
allow|H|python3 compile_experiment_evidence.py --plan data/task1/plan.json --collected "$(lattice-data path tetjet-slice/s1)"
allow|H|python3 -m lattice_batches publish --from data/task1 --fill-from-ledger
allow|H|python3 -m lattice_batches check --from data/task1 --fill-from-ledger
allow|H|python3 -m lattice_ranker table --out data/task1/table.csv
allow|H|python3 -m lattice_ranker coverage
allow|H|python3 -m lattice_ledger collect --source "$(lattice-data path tetjet-slice/s1)"
allow|H|python3 -m lattice_ledger import-experiment --source ~/lattice-store/items/tetjet-slice/s1
allow|H|curl -s -X POST http://127.0.0.1:8765/api/runs/E1/fetch
allow|H|lattice-data ingest data/task1/fetched --kind tetjet-slice --id s2
allow|H|rg foo data/task1/
# --- Fast paths and other ordinary reads ---
allow|H|lattice-data find --task task1
allow|H|lattice-data path tetjet-slice/s1
allow|H|lattice-data ls tetjet-slice/s1 --depth 2
allow|H|lattice-data grep tetjet-slice/s1 foo
allow|H|rg foo ~/lattice-store/items/tetjet-slice/s1
allow|H|find ~/lattice-store/items/tetjet-slice/s1 -name '*.json'
allow|H|du -sh ~/lattice-store/items/tetjet-slice/s1/fetched
allow|H|cat ~/lattice-store/catalog.jsonl
allow|H|grep foo ~/lattice-store/catalog.jsonl
allow|H|ls ~/lattice-store
allow|H|ls data/
allow|H|ls -la ~
allow|H|grep foo data/task1/report.md
allow|H|grep -r foo data/task1
allow|H|grep -rn foo ~/lattice-ledger/runs/E1.md
allow|T|rg foo
allow|T|find . -name '*.md'
allow|W|rg foo
allow|W|grep -rn foo .
allow|H|du -sh data/task1
allow|H|find ~/lattice-ledger/geometry/site -name '*.json'
allow|H|rg foo ~/lattice-ledger/search-recording/r1
allow|H|rg foo ~/.cache/pip
allow|H|git grep foo
allow|H|find ~ -maxdepth 1 -name x
allow|H|tree -L 1 ~
allow|H|rg --version
allow|H|ssh engineer@10.0.0.3 'ls /data/runs'
allow|H|ssh engineer@10.0.0.3 find /scratch/run1 -name x
# --- Protected roots ---
block|H|rg foo
block|H|grep -rn foo .
block|H|rg foo data/
block|H|rg foo data
block|H|ugrep foo data
block|H|grep -R foo ~
block|H|egrep -r foo /
block|H|fgrep --recursive foo ~
block|H|grep -d recurse foo ~
block|H|find / -name x
block|H|find /mnt/c -name x
block|H|ls -R /mnt
allow|H|du -sh /mnt/d
block|H|tree ~
block|H|ag foo ~/.cache
block|H|rg foo ~/lattice-store
block|H|find ~/lattice-store/items -name x
block|H|du -sh ~/lattice-store/items/tetjet-slice
block|H|rg foo ~/lattice-ledger/search-recording
block|H|rg foo ~/lattice-ledger/diagnostics
block|H|rg foo ~/lattice-ledger
block|H|du -sh data/rolling-runs-v11-2-1
block|H|du -sh data/rolling-runs-v11-2-1/slices
block|H|du -sh data/*
block|H|find data/exp2 -name x
block|H|rg foo data/exp2/tetjet-results
allow|H|rg foo data/exp2/tetjet-results/t1
block|S|rg foo
block|H|rg foo ~/.treehouse
block|H|du -sh ~/.treehouse/*/*/firstmate/data
block|~|rg foo
block|L|rg foo
block|L|find -name x
block|L|du -sh .
# --- Parsing edges ---
block|H|rg "foo bar" "$HOME"
block|H|rg 'foo' "${HOME}/"
allow|H|echo "grep -r foo ~"
allow|H|printf '%s\n' 'rg foo /'
allow|H|grep -e -r foo data/task1/report.md
allow|H|command -v rg
block|H|true && rg foo ~
block|H|echo hi; du -sh ~
block|H|ls | grep -r foo ~
block|H|false || find ~ -name x
block|H|echo one
find / -name x
block|H|bash -c 'cd ~ && rg foo'
block|H|sh -lc "grep -r foo /"
block|H|cd data && rg foo
allow|H|cd data/task1 && rg foo
allow|H|cd ~/lattice-store/items/tetjet-slice/s1 && rg foo
block|H|(cd ~ && du -sh .)
block|T|cd .. && rg foo
block|T|rg foo ../..
allow|T|rg foo ../task1
block|H|rg foo ~/link-store
block|H|rg foo ~/data-link
allow|H|rg foo ~/data-link/task1
block|H|du -sh ~/Tools/*/data
allow|H|rg foo data/task*
allow|H|du -sh ~/lattice-store/items/*/*
block|H|du -sh ~/lattice-store/items/*
allow|H|find data/task1 -name '*.md' | xargs grep -l foo
allow|H|git log --oneline | rg fix
allow|H|ps aux | ag node
allow|H|git log |& ugrep fix
allow|H|rg foo < data/task1/report.md
block|H|git log | grep -r fix
block|H|git log | rg fix ~
block|H|git log | find -name x
block|H|echo x | xargs grep -r foo ~
block|H|nice -n 19 ionice -c3 rg foo ~
block|H|timeout 60 du -sh ~
block|H|sudo find / -name x
block|H|env LC_ALL=C grep -r foo /
block|H|echo "$(find ~ -name x)"
block|H|ssh engineer@10.0.0.3 find / -name x
block|H|ssh -i key engineer@10.0.0.3 'grep -r foo ~'
block|H|ssh engineer@10.0.0.3 grep -r foo
allow|H|ssh engineer@10.0.0.3 'cd /srv/app && find . -name x'
block|H|ssh engineer@10.0.0.3 'cd / && find . -name x'
block|H|ssh engineer@10.0.0.3 'cd /srv && cd && find . -name x'
block|H|ssh engineer@10.0.0.3 find /mnt/c -name x
allow|H|ssh engineer@10.0.0.3 find /mnt/d -name x
EOF
)

# expect | cwd | tool | path | pattern
TOOL_TABLE=$(cat <<'EOF'
block|H|grep|||
allow|H|grep|data/task1|foo
allow|H|grep|~/lattice-ledger/runs/E1.md|foo
block|H|grep|~/lattice-store|foo
block|H|grep|/|foo
block|H|glob||**/*.md
block|H|glob||*.md
allow|H|glob|data/task1|**/*.md
block|H|glob|data|*.md
block|H|glob||data/task1/**/*.md
block|H|glob|~|*.md
allow|W|glob||**/*.ts
block|H|glob||~/**/*.md
block|W|glob||~/**/*.md
block|W|glob||/**/*.md
block|W|glob|src|~/lattice-store/**/*.json
allow|W|glob||~/lattice-ledger/runs/*.md
block|L|grep|||
block|L|glob||*.md
EOF
)

run_bash_table() {
  local failures=0 count=0 pending="" line
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$line" =~ ^(allow|block)\|[HTSW~L]\| ]]; then
      [ -n "$pending" ] && { run_bash_case "$pending" || failures=$((failures + 1)); count=$((count + 1)); }
      pending=$line
    else
      pending="$pending"$'\n'"$line"
    fi
  done <<<"$BASH_TABLE"
  [ -n "$pending" ] && { run_bash_case "$pending" || failures=$((failures + 1)); count=$((count + 1)); }
  [ "$failures" -eq 0 ] || fail "$failures of $count bash table rows failed"
  pass "bash table: all $count rows match (allow/block)"
}

run_bash_case() {
  local row=$1 expect cwd cmd code want
  expect=${row%%|*}
  row=${row#*|}
  cwd=$(cwd_of "${row%%|*}")
  cmd=${row#*|}
  want=0
  [ "$expect" = block ] && want=2
  gate enforce --harness pi --cwd "$cwd" --command "$cmd" >/dev/null 2>&1
  code=$?
  if [ "$code" != "$want" ]; then
    printf 'not ok - expected %s (exit %s), got exit %s: cwd=%s cmd=%s\n' "$expect" "$want" "$code" "$cwd" "$cmd" >&2
    return 1
  fi
}

test_bash_table() {
  run_bash_table
}

test_tool_table() {
  local expect key tool path pattern cwd code want args failures=0 count=0
  while IFS='|' read -r expect key tool path pattern; do
    case "$expect" in ''|'#'*) continue ;; esac
    count=$((count + 1))
    cwd=$(cwd_of "$key")
    args=(--harness claude --cwd "$cwd" --tool "$tool" --pattern "$pattern")
    [ -n "$path" ] && args+=(--path "$path")
    want=0
    [ "$expect" = block ] && want=2
    gate enforce "${args[@]}" >/dev/null 2>&1
    code=$?
    if [ "$code" != "$want" ]; then
      printf 'not ok - %s tool=%s path=%s pattern=%s cwd=%s: exit %s\n' "$expect" "$tool" "$path" "$pattern" "$cwd" "$code" >&2
      failures=$((failures + 1))
    fi
  done <<<"$TOOL_TABLE"
  [ "$failures" -eq 0 ] || fail "$failures of $count Grep/Glob table rows failed"
  pass "Grep/Glob table: all $count rows match"
}

expected_refusal() {
  cat <<EOF
BLOCKED (data gate): recursive $1 over $2 would scan bulk run data.
Use:  lattice-data find --task|--batch|--slice|--entry …   (catalog: ~/lattice-store/catalog.jsonl)
      lattice-data grep <item-id> PATTERN                   (search inside one item)
      ~/lattice-ledger/index.json and runs/<entry_id>.md    (run results)
See skill data-access. Override for a named small folder: search that folder directly.
EOF
}

claude_payload() {  # <cwd> <command>
  node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$1" "$2"
}

test_enforce_transports() {
  local payload out err code
  payload=$(claude_payload "$MAIN" 'rg foo')
  out=$(printf '%s' "$payload" | gate enforce --harness claude 2>"$TMP_ROOT/err")
  code=$?
  err=$(cat "$TMP_ROOT/err")
  expect_code 2 "$code" "claude-shaped deny exits 2"
  assert_equals "" "$out" "claude deny keeps stdout empty"
  assert_equals "$(expected_refusal rg "$MAIN")" "$err" "refusal text is exactly the plan's message"

  printf '%s' "$payload" | gate enforce --harness codex >/dev/null 2>&1
  expect_code 2 $? "codex-shaped deny exits 2"

  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],toolName:"Bash",toolInput:{command:"du -sh ~"}}))' "$MAIN")
  out=$(printf '%s' "$payload" | gate enforce --harness grok 2>/dev/null)
  assert_contains "$out" '"decision":"deny"' "grok deny object on stdout"
  printf '%s' "$out" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' || fail "grok deny object is valid JSON"

  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Grep",tool_input:{pattern:"foo"}}))' "$MAIN")
  printf '%s' "$payload" | gate enforce --harness claude >/dev/null 2>&1
  expect_code 2 $? "claude Grep tool without path over a home root is refused"
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Glob",tool_input:{pattern:"*.md",path:process.argv[1]}}))' "$MAIN")
  printf '%s' "$payload" | gate enforce --harness claude >/dev/null 2>&1
  expect_code 2 $? "claude Glob over a home root is refused by its path"
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Glob",tool_input:{pattern:"**/*.md",path:process.argv[1]+"/data/task1"}}))' "$MAIN")
  printf '%s' "$payload" | gate enforce --harness claude >/dev/null 2>&1
  expect_code 0 $? "claude Glob inside a small named folder is allowed"
  pass "enforce transports render per harness"
}

test_log_mode_default() {
  local log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl" out code before after last
  rm -f "$log"
  out=$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE "$GATE" --harness pi --cwd "$MAIN" --command 'rg foo' 2>&1)
  code=$?
  expect_code 0 "$code" "log mode (the default) allows a would-block call"
  assert_equals "" "$out" "log mode prints nothing"
  last=$(tail -n 1 "$log")
  printf '%s' "$last" | node -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    for (const k of ["ts", "harness", "cwd", "cmd", "verdict", "would_block"]) if (!(k in r)) throw new Error("missing " + k);
    if (r.verdict !== "allow" || r.would_block !== true || r.harness !== "pi" || r.cmd !== "rg foo") throw new Error(JSON.stringify(r));
  ' || fail "log record carries ts, harness, cwd, cmd, verdict=allow, would_block=true: $last"

  gate log --harness pi --cwd "$MAIN" --command 'rg foo data/task1' >/dev/null 2>&1
  tail -n 1 "$log" | grep -q '"would_block":false' || fail "an allowed scan is logged with would_block=false"

  before=$(wc -l <"$log")
  gate log --harness pi --cwd "$MAIN" --command 'git status' >/dev/null 2>&1
  gate log --harness pi --cwd "$MAIN" --command 'cat data/task1/report.md' >/dev/null 2>&1
  after=$(wc -l <"$log")
  assert_equals "$before" "$after" "non-scan commands are not logged"

  mkdir -p "$FAKE_HOME/.config/lattice-data-gate"
  printf 'enforce\n' >"$FAKE_HOME/.config/lattice-data-gate/mode"
  HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE "$GATE" --harness pi --cwd "$MAIN" --command 'rg foo' >/dev/null 2>&1
  expect_code 2 $? "config file mode=enforce is honored"
  gate log --harness pi --cwd "$MAIN" --command 'rg foo' >/dev/null 2>&1
  expect_code 0 $? "LATTICE_DATA_GATE overrides the config file"
  rm -f "$FAKE_HOME/.config/lattice-data-gate/mode"
  pass "log mode allows and records decisions"
}

test_bulk_dir_created_after_cache() {
  HOME="$FAKE_HOME" "$GATE" refresh >/dev/null || fail "refresh failed"
  mkdir -p "$MAIN/data/rolling-runs-v12/slices/s1" "$MAIN/data/exp3/tetjet-results"
  gate enforce --harness pi --cwd "$MAIN" --command 'du -sh data/rolling-runs-v12' >/dev/null 2>&1
  expect_code 2 $? "a rolling-runs dir created after the cache is refused"
  gate enforce --harness pi --cwd "$MAIN" --command 'find data/rolling-runs-v12/slices -name x' >/dev/null 2>&1
  expect_code 2 $? "its slices dir is refused"
  gate enforce --harness pi --cwd "$MAIN" --command 'rg foo data/exp3' >/dev/null 2>&1
  expect_code 2 $? "a new tetjet-results parent is refused"
  gate enforce --harness pi --cwd "$MAIN" --command 'rg foo data/rolling-runs-v12/slices/s1' >/dev/null 2>&1
  expect_code 0 $? "one named slice inside it is allowed"
  mkdir -p "$TMP_ROOT/off/rolling-runs-v13/slices/s1"
  ln -s "$TMP_ROOT/off/rolling-runs-v13" "$MAIN/data/rolling-runs-v13"
  gate enforce --harness pi --cwd "$MAIN" --command 'du -sh data/rolling-runs-v13' >/dev/null 2>&1
  expect_code 2 $? "a symlinked rolling-runs dir is refused"
  gate enforce --harness pi --cwd "$MAIN" --command 'find data/rolling-runs-v13/slices -name x' >/dev/null 2>&1
  expect_code 2 $? "the slices dir behind a symlink is refused"
  gate enforce --harness pi --cwd "$MAIN" --command 'rg foo data/rolling-runs-v13/slices/s1' >/dev/null 2>&1
  expect_code 0 $? "one named slice behind a symlink is allowed"
  rm -rf "$MAIN/data/rolling-runs-v12" "$MAIN/data/exp3" "$MAIN/data/rolling-runs-v13" "$TMP_ROOT/off"
  pass "bulk dirs created after the roots cache or reached by symlink are protected"
}

test_bulk_dirs_past_glob_cap() {
  local i
  for i in $(seq 1 300); do mkdir -p "$MAIN/data/many$i"; done
  mkdir -p "$MAIN/data/many5/tetjet-results/t1" "$MAIN/data/rolling-runs-v14/slices/s1" "$TMP_ROOT/off2/tr"
  ln -s "$TMP_ROOT/off2/tr" "$MAIN/data/many7/tetjet-results"
  gate enforce --harness pi --cwd "$MAIN" --command 'find data/many5/tetjet-results -name x' >/dev/null 2>&1
  expect_code 2 $? "a tetjet-results dir is refused past 256 data/ entries"
  gate enforce --harness pi --cwd "$MAIN" --command 'rg foo data/many5' >/dev/null 2>&1
  expect_code 2 $? "its parent is refused past 256 data/ entries"
  gate enforce --harness pi --cwd "$MAIN" --command 'du -sh data/many7/tetjet-results' >/dev/null 2>&1
  expect_code 2 $? "a symlinked tetjet-results dir is refused past 256 data/ entries"
  gate enforce --harness pi --cwd "$MAIN" --command 'cd data/many7/tetjet-results && du -sh .' >/dev/null 2>&1
  expect_code 2 $? "a symlinked bulk dir reached by cd is refused past 256 data/ entries"
  gate enforce --harness pi --cwd "$MAIN" --command "du -sh $TMP_ROOT/off2/tr" >/dev/null 2>&1
  expect_code 2 $? "a symlinked bulk dir named by its realpath is refused past 256 data/ entries"
  gate enforce --harness pi --cwd "$MAIN/data/many7/tetjet-results" --command 'rg foo' >/dev/null 2>&1
  expect_code 2 $? "pathless rg with cwd in a symlinked bulk dir is refused"
  gate enforce --harness pi --cwd "$MAIN/data/many7/tetjet-results" --command 'find -name x' >/dev/null 2>&1
  expect_code 2 $? "pathless find with cwd in a symlinked bulk dir is refused"
  gate enforce --harness claude --cwd "$MAIN/data/many7/tetjet-results" --tool grep --pattern foo >/dev/null 2>&1
  expect_code 2 $? "a pathless Grep tool with cwd in a symlinked bulk dir is refused"
  gate enforce --harness pi --cwd "$MAIN" --command 'du -sh data/rolling-runs-v14' >/dev/null 2>&1
  expect_code 2 $? "a rolling-runs dir is refused past 256 data/ entries"
  gate enforce --harness pi --cwd "$MAIN" --command 'rg foo data/many9' >/dev/null 2>&1
  expect_code 0 $? "a task folder without bulk dirs stays allowed"
  gate enforce --harness pi --cwd "$MAIN" --command 'rg foo data/many5/tetjet-results/t1' >/dev/null 2>&1
  expect_code 0 $? "one named folder inside a bulk dir stays allowed"
  rm -rf "$MAIN"/data/many* "$MAIN/data/rolling-runs-v14" "$TMP_ROOT/off2"
  pass "the glob cap never reduces bulk protection"
}

test_unknown_mode_is_log() {
  local log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl"
  assert_equals "log" "$(HOME="$FAKE_HOME" LATTICE_DATA_GATE=off "$GATE" mode)" "off is not a mode; it reads as log"
  gate off --harness pi --cwd "$MAIN" --command 'rg foo /' >/dev/null 2>&1
  expect_code 0 $? "an unknown mode allows"
  tail -n 1 "$log" | grep -q '"cmd":"rg foo /".*"would_block":true' || fail "an unknown mode still records like log"
  pass "an unknown mode behaves as log"
}

test_internal_error_allows_and_logs() {
  local copy="$TMP_ROOT/brokenbin" log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl"
  mkdir -p "$copy"
  cp "$GATE" "$copy/fm-data-gate.sh"
  printf 'throw new Error("boom");\n' >"$copy/fm-data-gate-policy.mjs"
  HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce "$copy/fm-data-gate.sh" --harness pi --cwd "$MAIN" --command 'rg foo /' >/dev/null 2>&1
  expect_code 0 $? "a broken policy steps aside even in enforce mode"
  tail -n 1 "$log" | grep -q '"error":"policy failed' || fail "the internal error is logged"
  printf '{not json' | HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness claude >/dev/null 2>&1
  expect_code 0 $? "unparseable stdin with a scan word allows"
  pass "internal errors allow and are logged"
}

test_home_discovery() {
  local roots
  roots=$(HOME="$FAKE_HOME" "$GATE" roots)
  assert_contains "$roots" "root $MAIN" "main home discovered"
  assert_contains "$roots" "root $SM/data" "secondmate home from the treehouse pool discovered"
  assert_contains "$roots" "bulk $MAIN/data/rolling-runs-*/slices" "bulk pattern from bulk-paths.txt"
  assert_contains "$roots" "bulk $MAIN/data/*/tetjet-results" "a */ bulk pattern is kept as a pattern"
  assert_not_contains "$roots" "root $WT" "a task worktree in the pool is not a home"
  pass "homes come from named registry and pool files"
}

# --- Size rule (docs/data-gate.md "The size rule") ---------------------------
# Sparse files (truncate -s, no disk use): ~/big holds 300 MiB copies of real
# read targets, ~/small the same names at a few bytes.
build_size_fixture() {
  local d f
  for d in big small; do
    mkdir -p "$FAKE_HOME/$d/services" "$FAKE_HOME/$d/fetched/workspace/ledger"
    for f in rolling.py tj_fill.py config.json sample.tsv final.json archive.tar review.txt entries.jsonl \
      services/a.conf services/b.conf COMPLETE STORED.md result.json fetched/workspace/ledger/workspace.json; do
      if [ "$d" = big ]; then truncate -s 300M "$FAKE_HOME/$d/$f"; else printf 'x\n' >"$FAKE_HOME/$d/$f"; fi
    done
  done
  mkdir -p "$FAKE_HOME/lattice-batches/fixture-prototype" "$MAIN/data/move-relayout-fx" "$MAIN/data/shell-runs-fx"
  printf '{"batch_id": "fixture-prototype"}\n' >"$FAKE_HOME/lattice-batches/fixture-prototype/lattice-batch.json"
  printf 'relayout-verdict-fx accepted\n' >"$MAIN/data/move-relayout-fx/report.md"
  printf 'relayout-verdict-fx accepted\n' >"$MAIN/data/shell-runs-fx/report.md"
  printf 'x\n' >"$WT/src/fm-disk-room.test.sh"
}

# expect | cwd | bash command. Each shape is a real read: "log #N" is record N
# of the gate's decision log (~/.local/state/lattice-data-gate/decisions.jsonl
# on the operator's machine, 2026-09-30), "S1r <id>" a read in lattice-research
# tests/fixtures/lattice-data/reads.jsonl; paths are mapped into ~/small or ~/big.
SIZE_BASH_TABLE=$(cat <<'EOF'
# log #52: windowed sed and grep through a variable set earlier in the command
allow|H|D=~/small; sed -n 445,465p $D/rolling.py; sed -n 575,590p $D/rolling.py; grep -n "^import\|^from\|transfer" $D/rolling.py | head -12
block|H|D=~/big; sed -n 445,465p $D/rolling.py
block|H|D=~/big; grep -n "^import\|transfer" $D/rolling.py | head -12
allow|H|D=~/big; sed -n '445,465p;465q' $D/rolling.py
# log #119: cat -n of a named test file
allow|W|cat -n src/fm-disk-room.test.sh
# log #98: globbed config cat into head, grep over two named files
allow|H|C=~/big; cat $C/services/*.conf 2>/dev/null | head -40
block|H|C=~/big; cat $C/services/*.conf 2>/dev/null
allow|H|C=~/small; grep -n -i -E 'floor|_gb|c_free' $C/tj_fill.py $C/config.json | head -50
block|H|C=~/big; grep -n -i -E 'floor|_gb|c_free' $C/tj_fill.py $C/config.json | head -50
# log #145, #65: checksums
allow|H|R7=~/small; sha256sum $R7/review.txt 2>/dev/null
block|H|sha256sum ~/big/archive.tar
allow|H|nice -n 19 ionice -c3 sha256sum ~/big/archive.tar
allow|H|nice -n19 ionice -c 3 bash -c 'sha256sum ~/big/archive.tar'
block|H|nice -n 19 sha256sum ~/big/archive.tar
allow|H|cd ~/big && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS.new
# log #171: awk over a named tsv
allow|H|cd ~/small; awk -F'\t' 'NR>1{print $2}' sample.tsv | sort | uniq -c
block|H|cd ~/big; awk -F'\t' 'NR>1{print $2}' sample.tsv | sort | uniq -c
# log #68, #103, #161: python heredocs and -c
allow|H|python3 - ~/big/rolling.py <<'PY'
import sys;p=sys.argv[1];s=open(p).read()
PY
block|H|python3 - <<'PY'
import json
d = json.load(open("REPLACED_BIG_FINAL"))
PY
allow|H|python3 - <<'PY'
f = open("REPLACED_BIG_FINAL"); f.seek(1000); print(f.read(4096))
PY
block|H|python3 -c 'import json; print(len(json.load(open("REPLACED_BIG_FINAL"))))'
allow|H|python3 -c 'import json; print(len(json.load(open("REPLACED_SMALL_FINAL"))))'
allow|H|python3 -m lattice_ledger show E1
# false blocks found in review: a Path stat and a write-mode open read nothing
allow|H|python3 -c "from pathlib import Path; print(Path('REPLACED_BIG_FINAL').stat().st_size)"
block|H|python3 -c "from pathlib import Path; print(len(Path('REPLACED_BIG_FINAL').read_text()))"
allow|H|python3 -c "open('REPLACED_BIG_FINAL', 'a').write('x')"
allow|H|python3 -c "open('REPLACED_BIG_FINAL', mode='wb').close()"
block|H|python3 -c "print(len(open('REPLACED_BIG_FINAL', 'rb').read()))"
# log #33, #76: virtual files
allow|H|cat /proc/meminfo | head -8; cat /proc/sys/vm/swappiness
# log #40, #159: head and tail always pass
allow|H|tail -3 ~/big/entries.jsonl; head -30 ~/big/rolling.py; head -c 8192 ~/big/final.json
allow|H|tail -n 50 < ~/big/entries.jsonl
block|H|wc -l < ~/big/entries.jsonl
# false blocks found in review: a byte count is a stat, not a read
allow|H|wc -c ~/big/entries.jsonl; wc --bytes ~/big/final.json; wc -c < ~/big/entries.jsonl
block|H|wc -lc ~/big/entries.jsonl
block|H|wc ~/big/entries.jsonl
block|H|while read -r line; do :; done < ~/big/entries.jsonl
allow|H|dd if=~/big/archive.tar bs=1M skip=10 count=4 status=none | xxd | head
block|H|dd if=~/big/archive.tar of=/dev/null bs=1M
allow|H|xxd -l 256 ~/big/archive.tar
allow|H|od -N 64 -c ~/big/archive.tar
block|H|less ~/big/entries.jsonl
block|H|jq '.rows | length' ~/big/final.json
allow|H|jq '.rows | length' ~/small/final.json
block|H|zcat ~/big/archive.tar
allow|H|zcat ~/big/archive.tar | head -100
block|H|export D=~/big; cut -f2 $D/sample.tsv
allow|H|cp ~/big/archive.tar ~/big/archive.copy
allow|H|echo "cat ~/big/final.json"
# S1r: the fixture's run and read calls
allow|H|lattice-data find-run R1
allow|H|lattice-data grep tetjet-slice/s1 R1 fetched/workspace/ledger -l
allow|H|python3 -m lattice_batches list --root ~/lattice-batches
allow|H|python3 -m lattice_batches report-due --receipts data/tetjet-offload/results --root ~/lattice-batches
allow|H|grep -rn relayout-verdict-fx data/move-relayout-fx/report.md data/shell-runs-fx/report.md
allow|H|cat ~/lattice-batches/fixture-prototype/lattice-batch.json
allow|H|cat ~/small/STORED.md; cat ~/small/COMPLETE; cat ~/small/result.json
allow|H|cat ~/small/fetched/workspace/ledger/workspace.json
allow|H|ls ~/big/fetched/workspace
block|H|cat ~/big/fetched/workspace/ledger/workspace.json
EOF
)

# expect | cwd | path | offset | limit: the Read tool (S1r read calls).
SIZE_READ_TABLE=$(cat <<'EOF'
allow|H|~/lattice-batches/fixture-prototype/lattice-batch.json||
allow|H|~/lattice-ledger/runs/E1.md||
allow|H|~/small/final.json||
allow|H|~/small/COMPLETE||
allow|H|~/small/STORED.md||
allow|H|~/small/result.json||
block|H|~/big/final.json||
allow|H|~/big/final.json|1|200
allow|H|~/big/final.json||50
allow|H|~/big/final.json|4000|
block|H|~/big/entries.jsonl||
allow|H|~/big||
allow|H|~/missing.json||
EOF
)

size_gate() {  # <size-mode> <args...>
  local mode=$1
  shift
  HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce LATTICE_DATA_GATE_SIZE="$mode" "$GATE" "$@"
}

test_size_bash_table() {
  local failures=0 count=0 pending="" line
  local big="$FAKE_HOME/big/final.json" small="$FAKE_HOME/small/final.json"
  size_case() {
    local row=$1 expect cwd cmd code want=0
    expect=${row%%|*}
    row=${row#*|}
    cwd=$(cwd_of "${row%%|*}")
    cmd=${row#*|}
    cmd=${cmd//REPLACED_BIG_FINAL/$big}
    cmd=${cmd//REPLACED_SMALL_FINAL/$small}
    [ "$expect" = block ] && want=2
    size_gate enforce --harness pi --cwd "$cwd" --command "$cmd" >/dev/null 2>&1
    code=$?
    [ "$code" = "$want" ] && return 0
    printf 'not ok - expected %s (exit %s), got exit %s: cwd=%s cmd=%s\n' "$expect" "$want" "$code" "$cwd" "$cmd" >&2
    return 1
  }
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$line" =~ ^(allow|block)\|[HTSW~L]\| ]]; then
      [ -n "$pending" ] && { size_case "$pending" || failures=$((failures + 1)); count=$((count + 1)); }
      pending=$line
    else
      pending="$pending"$'\n'"$line"
    fi
  done <<<"$SIZE_BASH_TABLE"
  [ -n "$pending" ] && { size_case "$pending" || failures=$((failures + 1)); count=$((count + 1)); }
  [ "$failures" -eq 0 ] || fail "$failures of $count size bash table rows failed"
  pass "size bash table: all $count rows match (allow/block)"
}

test_size_read_table() {
  local expect key path offset limit cwd code code2 want args payload failures=0 count=0 abs
  while IFS='|' read -r expect key path offset limit; do
    case "$expect" in ''|'#'*) continue ;; esac
    count=$((count + 1))
    cwd=$(cwd_of "$key")
    want=0
    [ "$expect" = block ] && want=2
    args=(--harness pi --cwd "$cwd" --tool read --path "$path")
    [ -n "$offset" ] && args+=(--offset "$offset")
    [ -n "$limit" ] && args+=(--limit "$limit")
    size_gate enforce "${args[@]}" >/dev/null 2>&1
    code=$?
    abs=${path/#\~/$FAKE_HOME}
    payload=$(node -e '
      const [cwd, file_path, offset, limit] = process.argv.slice(1);
      const input = { file_path };
      if (offset) input.offset = Number(offset);
      if (limit) input.limit = Number(limit);
      process.stdout.write(JSON.stringify({ session_id: "s", transcript_path: "/x/transcript_path.jsonl", cwd, tool_name: "Read", tool_input: input }));
    ' "$cwd" "$abs" "$offset" "$limit")
    printf '%s' "$payload" | size_gate enforce --harness claude >/dev/null 2>&1
    code2=$?
    if [ "$code" != "$want" ] || [ "$code2" != "$want" ]; then
      printf 'not ok - %s read path=%s offset=%s limit=%s\n' "$expect" "$path" "$offset" "$limit" >&2
      failures=$((failures + 1))
    fi
  done <<<"$SIZE_READ_TABLE"
  [ "$failures" -eq 0 ] || fail "$failures of $count Read table rows failed"
  pass "size Read table: all $count rows match through --tool read and the Claude payload"
}

expected_size_refusal() {  # <tool> <file>
  cat <<EOF
BLOCKED (data gate): $1 would read all of $2 (300 MiB; the whole-file limit is 200 MiB).
Use:  the file's DIGEST.md or its catalog entry first         (lattice-data find …)
      a bounded window: Read with offset and limit, head -c, tail -c, sed -n 'A,Bp;Bq'
      a niced one-off read: nice -n 19 ionice -c3 <command>, recorded in your report
See skill data-access, section "Blocked large read". If none of these fits, ask main.
EOF
}

test_size_refusal_and_modes() {
  local log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl" conf="$FAKE_HOME/.config/lattice-data-gate/mode"
  local big="$FAKE_HOME/big/final.json" err before
  err=$(size_gate enforce --harness pi --cwd "$MAIN" --command "cat $big" 2>&1 >/dev/null)
  assert_equals "$(expected_size_refusal cat "$big")" "$err" "the size refusal names the file, its size, the limit and the skill"

  rm -f "$log"
  size_gate log --harness pi --cwd "$MAIN" --command "cat $big" >/dev/null 2>&1
  expect_code 0 $? "size log mode allows a whole read over the limit while the scan rule enforces"
  tail -n 1 "$log" | node -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const t = r.targets[0];
    if (r.verdict !== "allow" || r.would_block !== true || JSON.stringify(r.would_block_rules) !== "[\"size\"]") throw new Error(JSON.stringify(r));
    if (r.mode !== "enforce" || r.size_mode !== "log" || r.size_limit !== 209715200) throw new Error(JSON.stringify(r));
    if (t.rule !== "size" || t.tool !== "cat" || t.size !== 314572800 || t.verdict !== "block") throw new Error(JSON.stringify(t));
  ' || fail "the would-block size read is recorded with its rule, size and modes"
  size_gate log --harness pi --cwd "$MAIN" --command 'rg foo' >/dev/null 2>&1
  expect_code 2 $? "the scan rule still enforces while the size rule logs"
  tail -n 1 "$log" | grep -q '"would_block_rules":\["scan"\]' || fail "a scan block names the scan rule"
  size_gate enforce --harness pi --cwd "$MAIN" --command "sed -n 1,5p\;5q $big" >/dev/null 2>&1
  tail -n 1 "$log" | grep -q '"why":"bounded"' || fail "a bounded read of a big file is recorded as an allowed size target"
  before=$(wc -l <"$log")
  size_gate enforce --harness pi --cwd "$MAIN" --command 'cat ~/small/final.json' >/dev/null 2>&1
  size_gate enforce --harness pi --cwd "$MAIN" --tool read --path "$FAKE_HOME/small/final.json" >/dev/null 2>&1
  assert_equals "$before" "$(wc -l <"$log")" "reads within the limit are never logged"

  mkdir -p "$(dirname "$conf")"
  printf 'enforce\nsize log\n' >"$conf"
  assert_equals "enforce" "$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE "$GATE" mode)" "the first word stays the scan rule's mode"
  assert_equals "log" "$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE_SIZE "$GATE" mode size)" "a size line sets the size rule's mode"
  HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE -u LATTICE_DATA_GATE_SIZE "$GATE" --harness pi --cwd "$MAIN" --command "cat $big" >/dev/null 2>&1
  expect_code 0 $? "size log from the file allows"
  HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE -u LATTICE_DATA_GATE_SIZE "$GATE" --harness pi --cwd "$MAIN" --command 'rg foo' >/dev/null 2>&1
  expect_code 2 $? "scan enforce from the same file refuses"
  HOME="$FAKE_HOME" LATTICE_DATA_GATE_SIZE=enforce "$GATE" --harness pi --cwd "$MAIN" --command "cat $big" >/dev/null 2>&1
  expect_code 2 $? "LATTICE_DATA_GATE_SIZE overrides the size line"

  printf 'log\n' >"$conf"
  assert_equals "enforce" "$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE_SIZE "$GATE" mode size)" "without a size line the size rule enforces by default"
  HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE -u LATTICE_DATA_GATE_SIZE "$GATE" --harness pi --cwd "$MAIN" --command "cat $big" >/dev/null 2>&1
  expect_code 2 $? "the default size mode refuses even when the scan rule logs"

  printf 'enforce\nsize-limit 1G\nsize log' >"$conf"
  assert_equals "log" "$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE_SIZE "$GATE" mode size)" "a last size line without a newline is read"
  printf 'enforce\nsize-limit 1G' >"$conf"
  assert_equals 1073741824 "$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE_SIZE_LIMIT "$GATE" size-limit)" "a last size-limit line without a newline is read"

  printf 'log\nsize enforce\nsize-limit 1G\n' >"$conf"
  assert_equals 1073741824 "$(HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE_SIZE_LIMIT "$GATE" size-limit)" "a size-limit line sets the limit"
  HOME="$FAKE_HOME" env -u LATTICE_DATA_GATE_SIZE "$GATE" --harness pi --cwd "$MAIN" --command "cat $big" >/dev/null 2>&1
  expect_code 0 $? "a file under a raised limit passes"
  HOME="$FAKE_HOME" LATTICE_DATA_GATE_SIZE_LIMIT=100M "$GATE" --harness pi --cwd "$MAIN" --command "cat $big" >/dev/null 2>&1
  expect_code 2 $? "LATTICE_DATA_GATE_SIZE_LIMIT overrides the size-limit line"
  assert_equals 209715200 "$(HOME="$FAKE_HOME" LATTICE_DATA_GATE_SIZE_LIMIT=lots "$GATE" size-limit)" "an invalid limit falls back to 200M"
  assert_equals 4096 "$(HOME="$FAKE_HOME" LATTICE_DATA_GATE_SIZE_LIMIT=4096 "$GATE" size-limit)" "a bare limit is bytes"
  rm -f "$conf"
  pass "the size rule has its own mode and limit beside the scan rule"
}

test_size_read_payload_transports() {
  local big="$FAKE_HOME/big/final.json" out
  out=$(printf '{"cwd":"%s","toolName":"Read","toolInput":{"file_path":"%s"}}' "$MAIN" "$big" | size_gate enforce --harness grok 2>/dev/null)
  assert_contains "$out" '"decision":"deny"' "a grok-shaped Read payload gets the deny object"
  printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"../../../big/final.json"}}' "$MAIN/data" | size_gate enforce --harness claude >/dev/null 2>&1
  expect_code 2 $? "a relative Read path resolves against the payload cwd"
  printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s\\u002ejson"}}' "$MAIN" "${big%.json}" | size_gate enforce --harness claude >/dev/null 2>&1
  expect_code 2 $? "an escaped Read path is decoded by the policy"
  printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s","offset":null}}' "$MAIN" "$big" | size_gate enforce --harness claude >/dev/null 2>&1
  expect_code 2 $? "a null offset is not a bound"
  pass "Read payloads reach the size rule in every transport"
}

test_size_internal_error_allows() {
  local copy="$TMP_ROOT/brokenbin2" log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl"
  mkdir -p "$copy"
  cp "$GATE" "$copy/fm-data-gate.sh"
  printf 'throw new Error("boom");\n' >"$copy/fm-data-gate-policy.mjs"
  HOME="$FAKE_HOME" LATTICE_DATA_GATE_SIZE=enforce "$copy/fm-data-gate.sh" --harness pi --cwd "$MAIN" --tool read --path "$FAKE_HOME/big/final.json" >/dev/null 2>&1
  expect_code 0 $? "a broken policy lets a big read through even in enforce mode"
  tail -n 1 "$log" | grep -q '"error":"policy failed' || fail "the size rule's internal error is logged"
  pass "size rule internal errors allow and are logged"
}

build_fixture
test_home_discovery
test_bash_table
test_bulk_dir_created_after_cache
test_bulk_dirs_past_glob_cap
test_tool_table
test_enforce_transports
test_log_mode_default
test_unknown_mode_is_log
test_internal_error_allows_and_logs
build_size_fixture
test_size_bash_table
test_size_read_table
test_size_refusal_and_modes
test_size_read_payload_transports
test_size_internal_error_allows
