#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the user-level data gate (docs/data-gate.md): the policy,
# its installer, and its read log and daily report.
#
# bin/fm-data-gate-policy.mjs owns the decision and bin/fm-data-gate.sh is the
# harness entry point. Every policy case runs against a fake HOME holding a fake
# main home, a treehouse pool with one secondmate home and one task worktree, a
# bulk store, a ledger, and symlinks, so nothing here reads or writes the real ~.
# The table covers every read in the data-storage plan's "Legitimate reads
# today" table as ALLOW, the protected roots as BLOCK, and the parsing edges.
#
# Installer cases (under $TMP_ROOT/install) run bin/fm-data-gate-install.sh with
# HOME pointed at a fresh temporary directory, never the real one: install,
# re-install (idempotent), uninstall (byte-identical restore), dry-run (writes
# nothing), uninstall after a later edit (only gate entries removed, even across
# a re-install), an unparseable settings file (left untouched), every registered
# Claude login folder, the generated bulk paths, the Codex trust entry, and the
# installed hooks, plugins and extensions actually calling the gate and logging
# reads, and the daily report timer (with a fake systemctl, so no user manager
# is touched). The fake systemctl is on PATH only inside the installer section.
#
# Read log cases (under $TMP_ROOT/reads): bin/fm-data-gate.sh passes every
# read-shaped call to bin/fm-data-gate-reads.mjs, which appends rows to
# reads-<date>.jsonl; bin/fm-data-gate-report.sh summarizes one day. They run
# against their own fake HOME, so nothing here reads or writes the real ~.
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
# Read-only size measurement: du -x of a measurable store root passes.
allow|H|du -shx ~/lattice-store
allow|H|du -sx --one-file-system ~/lattice-store/items/tetjet-slice
allow|H|du -shx data/rolling-runs-v11-2-1/slices
allow|H|du -shx data/exp2/tetjet-results
allow|H|du -shx ~/lattice-ledger/search-recording ~/lattice-ledger/diagnostics
allow|H|nice -n 19 ionice -c3 du -sx ~/lattice-store
allow|H|cd ~/lattice-store && du -sx
allow|H|du -shx ~/link-store
allow|H|df -h ~/lattice-store
allow|H|stat ~/lattice-store
block|H|du -shxL ~/lattice-store
block|H|du -shx --dereference ~/lattice-store
block|H|du -sx --files0-from=list ~/lattice-store
block|H|du -shx ~
block|H|du -shx /
block|H|du -shx data
block|H|du -shx .
block|H|du -shx data/rolling-runs-v11-2-1
block|H|du -shx data/*
block|H|du -shx ~/lattice-ledger
block|H|du -shx ~/lattice-store ~
block|H|rg foo ~/lattice-store
block|H|find -x ~/lattice-store -name x
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

test_measure_logs_why() {
  local log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl"
  gate enforce --harness pi --cwd "$MAIN" --command 'du -shx ~/lattice-store' >/dev/null 2>&1
  expect_code 0 $? "du -x of the store root passes in enforce"
  tail -n 1 "$log" | grep -q '"cmd":"du -shx ~/lattice-store".*"verdict":"allow".*"why":"measure"' || fail "a measurement target is logged with why measure"
  pass "a size measurement passes and is logged as why measure"
}

# A slow policy past LATTICE_DATA_GATE_TIMEOUT refuses a call an enforcing rule
# would look at, and allows (but logs) every other call.
test_timeout_refuses_enforced_calls() {
  local copy="$TMP_ROOT/slowbin" log="$FAKE_HOME/.local/state/lattice-data-gate/decisions.jsonl" err out
  mkdir -p "$copy"
  cp "$GATE" "$copy/fm-data-gate.sh"
  printf 'await new Promise((r) => setTimeout(r, 4000));\nprocess.stdout.write("allow\\n");\n' >"$copy/fm-data-gate-policy.mjs"
  slow() {  # <scan mode> <size mode> <args...>
    local mode=$1 size=$2
    shift 2
    HOME="$FAKE_HOME" LATTICE_DATA_GATE="$mode" LATTICE_DATA_GATE_SIZE="$size" LATTICE_DATA_GATE_TIMEOUT=1 \
      LATTICE_DATA_GATE_READS=off "$copy/fm-data-gate.sh" "$@"
  }
  err=$(slow enforce log --harness pi --cwd "$MAIN" --command 'rg foo /x' 2>&1 >/dev/null)
  expect_code 2 $? "a timed-out scan-shaped call is refused while the scan rule enforces"
  assert_contains "$err" "did not finish within 1 s" "the refusal says the check ran out of time"
  tail -n 1 "$log" | grep -q '"verdict":"block".*"timeout":true' || fail "the refused timeout is logged as a block with timeout true"
  out=$(printf '{"cwd":"%s","toolName":"Bash","toolInput":{"command":"rg foo /x"}}' "$MAIN" | slow enforce log --harness grok 2>/dev/null)
  assert_contains "$out" '"decision":"deny"' "a timed-out grok call gets the deny object"
  slow log enforce --harness pi --cwd "$MAIN" --tool read --path "$MAIN/data/task1/report.md" >/dev/null 2>&1
  expect_code 2 $? "a timed-out read is refused while the size rule enforces"
  slow enforce log --harness pi --cwd "$MAIN" --command "cat $MAIN/data/task1/report.md" >/dev/null 2>&1
  expect_code 0 $? "a timed-out read passes while only the scan rule enforces"
  tail -n 1 "$log" | grep -q '"verdict":"allow".*"timeout":true' || fail "the allowed timeout is logged with timeout true"
  slow log log --harness pi --cwd "$MAIN" --command 'rg foo /x' >/dev/null 2>&1
  expect_code 0 $? "a timed-out call passes while both rules log"
  pass "a policy timeout refuses calls an enforcing rule would check and allows the rest"
}

# The protected roots are built only when a scan needs classifying, so a plain
# read never lists the homes and bulk directories.
test_roots_built_lazily() {
  local h="$TMP_ROOT/lazyhome"
  mkdir -p "$h"
  printf 'x\n' >"$h/f"
  HOME="$h" LATTICE_DATA_GATE=enforce LATTICE_DATA_GATE_SIZE=enforce LATTICE_DATA_GATE_READS=off \
    "$GATE" --harness pi --cwd "$h" --command "cat $h/f" >/dev/null 2>&1
  expect_code 0 $? "a small read passes"
  assert_absent "$h/.local/state/lattice-data-gate/roots.json" "a read decision does not build the roots cache"
  HOME="$h" LATTICE_DATA_GATE=enforce LATTICE_DATA_GATE_READS=off \
    "$GATE" --harness pi --cwd "$h" --command "rg foo $h" >/dev/null 2>&1
  expect_code 2 $? "a scan of the home is refused"
  assert_present "$h/.local/state/lattice-data-gate/roots.json" "a scan decision builds the roots cache"
  pass "protected roots are built only for scans"
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

# --- Installer (bin/fm-data-gate-install.sh) --------------------------------
INSTALL_ROOT="$TMP_ROOT/install"
INSTALL_FAKEBIN=$(fm_fakebin "$INSTALL_ROOT")
cat >"$INSTALL_FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
SH
chmod +x "$INSTALL_FAKEBIN/systemctl"
INSTALL="$ROOT/bin/fm-data-gate-install.sh"

AXI_HOOKS='{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "gh-axi", "timeout": 10}]},
      {"matcher": "", "hooks": [{"type": "command", "command": "chrome-devtools-axi", "timeout": 10}]},
      {"matcher": "", "hooks": [{"type": "command", "command": "lavish-axi", "timeout": 10}]}
    ]
  },
  "theme": "dark"
}'

new_home() {  # <name>
  local h="$INSTALL_ROOT/$1"
  mkdir -p "$h/.claude" "$h/.claude-work" "$h/.claude-gmail" "$h/.claude-tetmet" "$h/.codex" "$h/.codex-alt" \
    "$h/.grok" "$h/.config/opencode" "$h/.pi/agent" "$h/.omp/agent/extensions" "$h/Tools/firstmate/bin" \
    "$h/Tools/firstmate/config" "$h/Tools/firstmate/data/rolling-runs-v9/slices" \
    "$h/Tools/firstmate/data/exp/tetjet-results" "$h/lattice-ledger"
  : >"$h/Tools/firstmate/AGENTS.md"
  printf 'gmail claude ~/.claude-gmail 1\ntetmet claude %s/.claude-tetmet 2\nwork claude ~/.claude-work 3\nalt codex ~/.codex-alt\n' "$h" \
    >"$h/Tools/firstmate/config/accounts"
  printf 'rolling-runs-v9/slices\n' >"$h/Tools/firstmate/data/bulk-paths.txt"
  printf '%s\n' "$AXI_HOOKS" >"$h/.claude/settings.json"
  printf '%s' "$AXI_HOOKS" >"$h/.codex/hooks.json"
  printf 'scratch/\n' >"$h/lattice-ledger/.ignore"
  printf 'model = "x"\n' >"$h/.codex/config.toml"
  printf '%s\n' "$h"
}

snapshot() {  # <home>: hash every file outside the installer's own state dir
  (cd "$1" && find . -path ./.local -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$f"
  done
  find . -path ./.local -prune -o -type d -print | LC_ALL=C sort)
}

inst() {  # <home> <args...>
  local h=$1
  shift
  HOME="$h" "$INSTALL" "$@"
}

test_dry_run_writes_nothing() {
  local h before out
  h=$(new_home dry)
  before=$(snapshot "$h")
  out=$(inst "$h" install --dry-run) || fail "dry-run install failed: $out"
  assert_contains "$out" "dry run: nothing was written" "dry run says so"
  assert_contains "$out" "changed   $h/.claude/settings.json" "dry run still prints the per-file summary"
  assert_equals "$before" "$(snapshot "$h")" "dry-run install changes no file"
  assert_absent "$h/.local/state/lattice-data-gate" "dry-run install writes no state"
  inst "$h" install >/dev/null || fail "install failed"
  before=$(snapshot "$h")
  inst "$h" uninstall --dry-run >/dev/null || fail "dry-run uninstall failed"
  assert_equals "$before" "$(snapshot "$h")" "dry-run uninstall changes no file"
  pass "dry-run changes nothing"
}

test_install_merges_and_backs_up() {
  local h out backups
  h=$(new_home merge)
  out=$(inst "$h" install) || fail "install failed: $out"
  for f in .claude/settings.json .claude-work/settings.json .claude-gmail/settings.json .claude-tetmet/settings.json \
    .codex/hooks.json .codex/config.toml .grok/hooks/lattice-data-gate.json \
    .config/opencode/plugins/lattice-data-gate.js .pi/agent/extensions/lattice-data-gate.ts \
    .omp/agent/extensions/lattice-data-gate.ts Tools/firstmate/data/bulk-paths.txt \
    Tools/firstmate/data/.ignore Tools/firstmate/data/.rgignore \
    lattice-ledger/.ignore lattice-ledger/.rgignore .config/lattice-data-gate/mode; do
    assert_present "$h/$f" "install writes $f"
    assert_contains "$out" "$h/$f" "summary names $f"
  done
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const cmds = s.hooks.SessionStart.map((g) => g.hooks[0].command).join(",");
    if (cmds !== "gh-axi,chrome-devtools-axi,lavish-axi") throw new Error("SessionStart disturbed: " + cmds);
    if (s.theme !== "dark") throw new Error("other keys disturbed");
    const pre = s.hooks.PreToolUse;
    if (pre.length !== 1 || pre[0].matcher !== "Bash|Grep|Glob|Read" || !pre[0].hooks[0].command.includes("fm-data-gate.sh")) throw new Error(JSON.stringify(pre));
  ' "$h/.claude/settings.json" || fail "claude settings keep existing entries and gain one gate entry"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (s.hooks.SessionStart.length !== 3 || s.hooks.PreToolUse[0].matcher !== "Bash") throw new Error("codex merge wrong");
  ' "$h/.codex/hooks.json" || fail "codex hooks keep axi entries and gain a Bash gate entry"
  assert_absent "$h/.codex-alt/settings.json" "a Codex account folder gets no Claude settings"
  assert_equals "log"$'\n'"size log" "$(cat "$h/.config/lattice-data-gate/mode")" "a fresh mode file puts both rules in log"
  assert_equals "log" "$(HOME="$h" env -u LATTICE_DATA_GATE "$GATE" mode)" "the gate reads mode log"
  assert_equals "log" "$(HOME="$h" env -u LATTICE_DATA_GATE_SIZE "$GATE" mode size)" "the gate reads the size rule's mode log"
  assert_grep "rolling-runs-v9/slices/" "$h/Tools/firstmate/data/.rgignore" "home ignore lists its bulk paths"
  assert_grep "search-recording/" "$h/lattice-ledger/.ignore" "ledger ignore lists search-recording"
  assert_grep "scratch/" "$h/lattice-ledger/.ignore" "an existing ignore entry is kept"
  backups=$(find "$h/.local/state/lattice-data-gate/backups" -type f | wc -l)
  assert_equals 5 "$((backups))" "every pre-existing file touched is backed up (claude, codex hooks and config, bulk paths, ledger .ignore)"
  cmp -s "$(find "$h/.local/state/lattice-data-gate/backups" -path '*/.claude/settings.json')" <(printf '%s\n' "$AXI_HOOKS") \
    || fail "the claude backup holds the exact pre-install bytes"
  assert_grep 'model = "x"' "$h/.codex/config.toml" "the Codex config keeps its own settings"
  pass "install merges without disturbing entries and backs up each touched file"
}

test_generated_bulk_paths_feed_gate_and_ignores() {
  local h roots data
  h=$(new_home bulk)
  data="$h/Tools/firstmate/data"
  inst "$h" install >/dev/null || fail "install failed"
  assert_grep 'rolling-runs-v9/slices' "$data/bulk-paths.txt" "the home's own bulk line is kept"
  for entry in 'rolling-runs-*/slices/' '*/tetjet-results/' 'shell-contact-first-runs/runs*/'; do
    assert_grep "$entry" "$data/bulk-paths.txt" "bulk-paths.txt is generated with $entry"
    assert_grep "$entry" "$data/.rgignore" ".rgignore lists the generated $entry"
  done
  roots=$(HOME="$h" "$GATE" roots)
  assert_contains "$roots" "bulk $data/*/tetjet-results" "the gate protects the generated bulk patterns"
  HOME="$h" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$h/Tools/firstmate" --command 'du -sh data/exp' >/dev/null 2>&1
  expect_code 2 $? "a scan over a generated bulk dir's parent is refused"
  HOME="$h" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$h/Tools/firstmate" --command 'find data/rolling-runs-v9 -name x' >/dev/null 2>&1
  expect_code 2 $? "a scan over a rolling-runs dir is refused"
  pass "one generated bulk definition feeds the gate and the ignore files"
}

test_reinstall_is_idempotent() {
  local h first out backups_before backups_after
  h=$(new_home idem)
  inst "$h" install >/dev/null || fail "install failed"
  first=$(snapshot "$h")
  backups_before=$(find "$h/.local/state/lattice-data-gate/backups" -type f | wc -l)
  out=$(inst "$h" install) || fail "re-install failed"
  assert_equals "$first" "$(snapshot "$h")" "re-install changes no file"
  if printf '%s\n' "$out" | grep -qE '^(changed|created) '; then fail "re-install reports a change: $out"; fi
  backups_after=$(find "$h/.local/state/lattice-data-gate/backups" -type f | wc -l)
  assert_equals "$backups_before" "$backups_after" "re-install takes no new backup"
  pass "re-install is idempotent"
}

test_uninstall_restores_bytes() {
  local h before out
  h=$(new_home restore)
  before=$(snapshot "$h")
  inst "$h" install >/dev/null || fail "install failed"
  inst "$h" install >/dev/null || fail "re-install failed"
  out=$(inst "$h" uninstall) || fail "uninstall failed: $out"
  assert_equals "$before" "$(snapshot "$h")" "uninstall restores every file and directory byte-identically"
  assert_contains "$out" "restored  $h/.claude/settings.json" "summary names the restore"
  assert_absent "$h/.local/state/lattice-data-gate/install-manifest.json" "uninstall clears the manifest"
  pass "uninstall restores byte-identical pre-install content"
}

test_reinstall_after_edit_keeps_edits() {
  local h data
  h=$(new_home reedit)
  data="$h/Tools/firstmate/data"
  inst "$h" install >/dev/null || fail "install failed"
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.model = "opus";
    s.permissions = { allow: ["Bash(ls)"] };
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' "$h/.claude/settings.json"
  printf 'mine/\n' >>"$data/.ignore"
  printf 'extra-bulk/\n' >>"$data/bulk-paths.txt"
  inst "$h" install --gate "$INSTALL_ROOT/elsewhere/fm-data-gate.sh" >/dev/null || fail "re-install failed"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const text = JSON.stringify(s);
    if (text.includes("fm-data-gate.sh")) throw new Error("gate entry left behind");
    if (s.model !== "opus" || s.permissions?.allow?.[0] !== "Bash(ls)" || s.theme !== "dark") throw new Error("edits lost: " + text);
  ' "$h/.claude/settings.json" || fail "edits made between two installs survive uninstall"
  assert_equals "mine/" "$(cat "$data/.ignore")" "an ignore line added between installs survives uninstall"
  assert_equals "$(printf 'rolling-runs-v9/slices\nextra-bulk/')" "$(cat "$data/bulk-paths.txt")" "bulk lines added between installs survive uninstall"
  assert_no_grep 'pre_tool_use' "$h/.codex/config.toml" "no Codex trust entry is left behind"
  pass "a re-install after edits never makes uninstall discard them"
}

test_uninstall_after_edit_strips_only_gate() {
  local h
  h=$(new_home edited)
  inst "$h" install >/dev/null || fail "install failed"
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.hooks.PreToolUse.push({ matcher: "Edit", hooks: [{ type: "command", command: "my-own-hook" }] });
    s.model = "opus";
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' "$h/.claude/settings.json"
  printf 'mine/\n' >>"$h/Tools/firstmate/data/.ignore"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const text = JSON.stringify(s);
    if (text.includes("fm-data-gate.sh")) throw new Error("gate entry left behind");
    if (!text.includes("my-own-hook") || s.model !== "opus" || s.hooks.SessionStart.length !== 3) throw new Error("later edits lost: " + text);
  ' "$h/.claude/settings.json" || fail "uninstall after an edit removes only the gate entry"
  assert_equals "mine/" "$(cat "$h/Tools/firstmate/data/.ignore")" "uninstall keeps a later ignore line and drops only the gate block"
  pass "uninstall after later edits removes only the gate entries"
}

test_unparseable_settings_left_untouched() {
  local h out
  h=$(new_home broken)
  printf '{ not json\n' >"$h/.claude/settings.json"
  out=$(inst "$h" install) || fail "install failed"
  assert_contains "$out" "skipped   $h/.claude/settings.json" "an unparseable file is reported"
  assert_equals '{ not json' "$(cat "$h/.claude/settings.json")" "an unparseable file is left untouched"
  pass "unparseable settings are skipped, not clobbered"
}

test_only_existing_harnesses() {
  local h out
  h="$INSTALL_ROOT/bare"
  mkdir -p "$h/.claude"
  out=$(inst "$h" install) || fail "install failed"
  assert_absent "$h/.codex" "no codex dir is created"
  assert_absent "$h/.pi" "no pi dir is created"
  assert_present "$h/.claude/settings.json" "claude settings created where ~/.claude exists"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  assert_absent "$h/.claude/settings.json" "uninstall removes a settings file install created"
  pass "only harnesses with a user config dir are touched"
}

test_installed_adapters_call_the_gate() {
  local h cmd payload cwd="$INSTALL_ROOT/adapters/Tools/firstmate"
  h=$(new_home adapters)
  inst "$h" install >/dev/null || fail "install failed"
  printf 'enforce\nsize enforce\n' >"$h/.config/lattice-data-gate/mode"
  truncate -s 300M "$cwd/big.bin"
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"rg foo"}}))' "$cwd")

  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.claude/settings.json")
  printf '%s' "$payload" | HOME="$h" env -u GROK_AGENT -u GROK_HOOK_EVENT sh -c "$cmd" >/dev/null 2>&1
  expect_code 2 $? "the installed Claude hook command refuses a home-root scan"
  printf '%s' "$payload" | HOME="$h" GROK_AGENT=1 sh -c "$cmd" >/dev/null 2>&1
  expect_code 0 $? "the Claude hook stands down under Grok"
  printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s/big.bin"}}' "$cwd" "$cwd" \
    | HOME="$h" env -u GROK_AGENT -u GROK_HOOK_EVENT sh -c "$cmd" >/dev/null 2>&1
  expect_code 2 $? "the installed Claude hook refuses a whole Read of a file over the limit"
  printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s/big.bin","offset":1,"limit":50}}' "$cwd" "$cwd" \
    | HOME="$h" env -u GROK_AGENT -u GROK_HOOK_EVENT sh -c "$cmd" >/dev/null 2>&1
  expect_code 0 $? "the installed Claude hook allows a Read with offset and limit"

  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.codex/hooks.json")
  printf '%s' "$payload" | HOME="$h" sh -c "$cmd" >/dev/null 2>&1
  expect_code 2 $? "the installed Codex hook command refuses a home-root scan"

  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.grok/hooks/lattice-data-gate.json")
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],toolName:"Bash",toolInput:{command:"rg foo"}}))' "$cwd")
  printf '%s' "$payload" | HOME="$h" sh -c "$cmd" 2>/dev/null | grep -q '"decision":"deny"' || fail "the installed Grok hook prints a deny decision"

  if [ "$(node -p 'Boolean(process.features.typescript)' 2>/dev/null)" != true ]; then
    pass "this node cannot load TypeScript; the Pi extension check is skipped here"
  else
  HOME="$h" node --input-type=module -e '
    const [ext, cwd] = process.argv.slice(1);
    const mod = await import(ext);
    const handlers = {};
    mod.default({ on: (name, fn) => { handlers[name] = fn; } });
    const blocked = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: "rg foo" } }, { cwd });
    if (!blocked.block || !blocked.reason.startsWith("BLOCKED (data gate)")) throw new Error("pi did not block: " + JSON.stringify(blocked));
    const allowed = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: "rg foo data" } }, { cwd: cwd + "/bin" });
    if (allowed.block) throw new Error("pi blocked an allowed call");
    const grep = await handlers.tool_call({ type: "tool_call", toolName: "grep", input: { pattern: "x", path: "/" } }, { cwd });
    if (!grep.block) throw new Error("pi grep tool over / not blocked");
    const read = await handlers.tool_call({ type: "tool_call", toolName: "read", input: { path: "big.bin" } }, { cwd });
    if (!read.block || !read.reason.includes("Blocked large read")) throw new Error("pi whole read of a big file not blocked: " + JSON.stringify(read));
    const window = await handlers.tool_call({ type: "tool_call", toolName: "read", input: { path: "big.bin", offset: 1, limit: 20 } }, { cwd });
    if (window.block) throw new Error("pi blocked a bounded read");
  ' "$h/.pi/agent/extensions/lattice-data-gate.ts" "$cwd" 2>&1 || fail "the installed Pi extension blocks through the gate"
  fi

  HOME="$h" node --input-type=module -e '
    const [plugin, cwd] = process.argv.slice(1);
    const mod = await import(plugin);
    const hooks = await mod.LatticeDataGate({ directory: cwd });
    let threw = false;
    try { await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "du -sh ~" } }); } catch (e) { threw = e.message.startsWith("BLOCKED (data gate)"); }
    if (!threw) throw new Error("opencode did not block");
    await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } });
    threw = false;
    try { await hooks["tool.execute.before"]({ tool: "read" }, { args: { filePath: cwd + "/big.bin" } }); } catch (e) { threw = e.message.includes("Blocked large read"); }
    if (!threw) throw new Error("opencode did not block a whole read of a big file");
    await hooks["tool.execute.before"]({ tool: "read" }, { args: { filePath: cwd + "/big.bin", offset: 0, limit: 10 } });
  ' "$h/.config/opencode/plugins/lattice-data-gate.js" "$cwd" 2>&1 || fail "the installed OpenCode plugin blocks through the gate"
  rm -f "$cwd/big.bin"
  pass "installed Claude, Codex, Grok, Pi and OpenCode adapters call the gate"
}

test_installed_adapters_log_reads() {
  local h cmd payload reads cwd
  h=$(new_home readlog)
  cwd="$h/Tools/firstmate"
  reads="$h/.local/state/lattice-data-gate/reads-$(date +%F).jsonl"
  inst "$h" install >/dev/null || fail "install failed"
  printf 'enforce\n' >"$h/.config/lattice-data-gate/mode"
  printf 'hello\n' >"$cwd/claude.txt"
  cp "$cwd/claude.txt" "$cwd/opencode.txt"
  cp "$cwd/claude.txt" "$cwd/pi.txt"

  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],session_id:"s1",tool_name:"Read",tool_input:{file_path:process.argv[1]+"/claude.txt"}}))' "$cwd")
  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.claude/settings.json")
  printf '%s' "$payload" | HOME="$h" env -u GROK_AGENT -u GROK_HOOK_EVENT sh -c "$cmd" >/dev/null 2>&1
  expect_code 0 $? "the installed Claude hook allows a Read in enforce mode"
  assert_grep "\"harness\":\"claude\",\"home\":\"$cwd\"" "$reads" "the installed Claude hook logs a Read"

  HOME="$h" node --input-type=module -e '
    const [plugin, cwd] = process.argv.slice(1);
    const mod = await import(plugin);
    const hooks = await mod.LatticeDataGate({ directory: cwd });
    await hooks["tool.execute.before"]({ tool: "read" }, { args: { filePath: cwd + "/opencode.txt", limit: 1 } });
  ' "$h/.config/opencode/plugins/lattice-data-gate.js" "$cwd" 2>&1 || fail "the installed OpenCode plugin passes a read"
  grep -q '"harness":"opencode".*opencode.txt.*"lines":1' "$reads" || fail "the installed OpenCode plugin logs a bounded read"

  if [ "$(node -p 'Boolean(process.features.typescript)' 2>/dev/null)" != true ]; then
    pass "this node cannot load TypeScript; the Pi read check is skipped here"
  else
  HOME="$h" node --input-type=module -e '
    const [ext, cwd] = process.argv.slice(1);
    const mod = await import(ext);
    const handlers = {};
    mod.default({ on: (name, fn) => { handlers[name] = fn; } });
    const result = await handlers.tool_call({ type: "tool_call", toolName: "read", input: { path: cwd + "/pi.txt" } }, { cwd });
    if (result.block) throw new Error("pi blocked a read");
  ' "$h/.pi/agent/extensions/lattice-data-gate.ts" "$cwd" 2>&1 || fail "the installed Pi extension passes a read"
  grep -q '"harness":"pi".*pi.txt' "$reads" || fail "the installed Pi extension logs a read"
  fi
  pass "installed Claude, OpenCode and Pi adapters log reads without blocking them"
}

test_reinstall_upgrades_old_claude_matcher() {
  local h matcher
  h=$(new_home upgrade)
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash|Grep|Glob","hooks":[{"type":"command","command":"exec /old/fm-data-gate.sh --harness claude","timeout":10}]},{"matcher":"Bash","hooks":[{"type":"command","command":"other"}]}]}}\n' >"$h/.claude/settings.json"
  inst "$h" install >/dev/null || fail "install failed"
  matcher=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse; process.stdout.write(p.map((g)=>g.matcher).join(","))' "$h/.claude/settings.json")
  assert_equals "Bash|Grep|Glob|Read,Bash" "$matcher" "an earlier gate entry is upgraded to match Read in place"
  pass "re-install upgrades an earlier Claude gate entry to include Read"
}

# Codex's hook trust contract (codex-rs hooks discovery): the key is
# "<hooks.json>:pre_tool_use:<group>:<handler>" and the hash is sha256 over the
# key-sorted compact JSON of {event_name, matcher, hooks:[normalized handler]}.
codex_expected_trust() {  # <hooks.json>
  node -e '
    const crypto = require("crypto");
    const path = process.argv[1];
    const groups = JSON.parse(require("fs").readFileSync(path, "utf8")).hooks.PreToolUse;
    const g = groups.findIndex((x) => x.hooks.some((k) => k.command.includes("fm-data-gate.sh")));
    const k = groups[g].hooks.findIndex((x) => x.command.includes("fm-data-gate.sh"));
    const hook = groups[g].hooks[k];
    const id = JSON.stringify({ event_name: "pre_tool_use", hooks: [{ async: false, command: hook.command, timeout: hook.timeout, type: "command" }], matcher: groups[g].matcher });
    process.stdout.write(`[hooks.state."${path}:pre_tool_use:${g}:${k}"]\ntrusted_hash = "sha256:${crypto.createHash("sha256").update(id).digest("hex")}"`);
  ' "$1"
}

test_codex_trust_and_status() {
  local h out
  h=$(new_home status)
  printf '[hooks.state."%s:pre_tool_use:0:0"]\ntrusted_hash = "sha256:old"\n\n[tui]\nx = 1\n' "$h/.codex/hooks.json" >>"$h/.codex/config.toml"
  out=$(inst "$h" status) || fail "status failed"
  assert_contains "$out" "missing   $h/.claude/settings.json" "status before install"
  assert_contains "$out" "missing   $h/.codex/config.toml" "no Codex trust before install"
  inst "$h" install >/dev/null || fail "install failed"
  assert_contains "$(cat "$h/.codex/config.toml")" "$(codex_expected_trust "$h/.codex/hooks.json")" "install records Codex's trust hash for exactly the gate hook"
  assert_equals 1 "$(grep -c 'pre_tool_use:0:0' "$h/.codex/config.toml")" "a stale entry at the gate hook's key is replaced, not duplicated"
  assert_grep 'x = 1' "$h/.codex/config.toml" "other Codex tables are kept"
  out=$(inst "$h" status) || fail "status failed"
  assert_contains "$out" "mode      log" "status shows the mode"
  assert_contains "$out" "size      log, limit 209715200 bytes" "status shows the size rule's mode and limit"
  assert_contains "$out" "installed $h/.codex/hooks.json" "status after install"
  assert_contains "$out" "installed $h/.codex/config.toml" "status sees the Codex trust entry"
  printf '[later]\ny = 2\n' >>"$h/.codex/config.toml"
  if inst "$h" install | grep -q "^changed   $h/.codex/config.toml"; then fail "a re-install rewrote a current Codex trust entry"; fi
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  assert_no_grep 'fm-data-gate' "$h/.codex/hooks.json" "uninstall removes the Codex hook"
  assert_no_grep 'pre_tool_use' "$h/.codex/config.toml" "uninstall removes the Codex trust entry"
  assert_grep 'y = 2' "$h/.codex/config.toml" "uninstall keeps later Codex settings"
  pass "install records the Codex trust hash and status reports it"
}

unit_value() {  # <unit file> <section> <key>: the key's value, parsed as systemd reads it
  node -e '
    const [file, section, key] = process.argv.slice(1);
    let current = "";
    for (const raw of require("fs").readFileSync(file, "utf8").split("\n")) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const header = line.match(/^\[(.+)\]$/);
      if (header) current = header[1];
      else if (current === section && line.slice(0, line.indexOf("=")) === key) process.stdout.write(line.slice(line.indexOf("=") + 1));
    }' "$1" "$2" "$3"
}

test_report_timer() {
  local h units service timer exec out
  h=$(new_home timer)
  units="$h/.config/systemd/user"
  service="$units/lattice-data-gate-report.service"
  timer="$units/lattice-data-gate-report.timer"
  : >"$FAKE_SYSTEMCTL_LOG"
  out=$(inst "$h" install --dry-run) || fail "dry-run install failed"
  assert_contains "$out" "would enable lattice-data-gate-report.timer" "dry run names the timer"
  assert_equals "" "$(cat "$FAKE_SYSTEMCTL_LOG")" "dry run calls no systemctl"
  out=$(inst "$h" install) || fail "install failed"
  assert_contains "$out" "enabled lattice-data-gate-report.timer" "install reports the timer enabled"
  assert_equals "--user daemon-reload
--user enable --now lattice-data-gate-report.timer" "$(cat "$FAKE_SYSTEMCTL_LOG")" "install reloads the user manager and enables the timer"
  assert_equals "oneshot|19|idle" "$(unit_value "$service" Service Type)|$(unit_value "$service" Service Nice)|$(unit_value "$service" Service IOSchedulingClass)" \
    "the report runs as a oneshot at nice 19 in the idle IO class"
  assert_equals "*-*-* 00:40:00|true|timers.target" "$(unit_value "$timer" Timer OnCalendar)|$(unit_value "$timer" Timer Persistent)|$(unit_value "$timer" Install WantedBy)" \
    "the timer fires daily shortly after midnight and catches up a missed run"
  exec=$(unit_value "$service" Service ExecStart)
  out=$(HOME="$h" sh -c "$exec") || fail "the service's ExecStart does not run the report: $out"
  assert_contains "$out" "Data gate $(date -d yesterday +%F): agents read" "the service's ExecStart writes yesterday's report"
  assert_present "$h/.local/state/lattice-data-gate/reports/$(date -d yesterday +%F).md" "and the report file"
  out=$(inst "$h" status) || fail "status failed"
  assert_contains "$out" "installed $timer" "status sees the timer unit"
  : >"$FAKE_SYSTEMCTL_LOG"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  assert_equals "--user disable --now lattice-data-gate-report.timer
--user daemon-reload" "$(cat "$FAKE_SYSTEMCTL_LOG")" "uninstall disables the timer and reloads the user manager"
  assert_absent "$units" "uninstall removes the units and the unit directory it created"
  mkdir -p "$INSTALL_ROOT/no-systemctl"
  out=$(PATH="$INSTALL_ROOT/no-systemctl" HOME="$h" "$(command -v node)" "$ROOT/bin/fm-data-gate-install.mjs" install) || fail "install without systemctl failed"
  assert_contains "$out" "not enabled lattice-data-gate-report.timer (systemctl not found); run: systemctl --user daemon-reload" "install without systemctl says how to enable the timer"
  assert_present "$timer" "and still writes the units"
  pass "install writes and enables the daily report timer, and uninstall disables and removes it"
}

# --- Read log and daily report (bin/fm-data-gate-reads.mjs, fm-data-gate-report.sh)
READS_ROOT="$TMP_ROOT/reads"
READS_HOME="$READS_ROOT/home"
REPORT="$ROOT/bin/fm-data-gate-report.sh"
READS_MAIN="$READS_HOME/Tools/firstmate"
READS_WT="$READS_ROOT/pool/1/project"
READS_STATE="$READS_HOME/.local/state/lattice-data-gate"

build_reads_fixture() {
  mkdir -p "$READS_MAIN/bin" "$READS_MAIN/data/big" "$READS_MAIN/data/other" "$READS_MAIN/state" "$READS_WT"
  : >"$READS_MAIN/AGENTS.md"
  : >"$READS_MAIN/state/wt-task.status"
  seq 1 1000 >"$READS_MAIN/data/big/lines.txt"
  truncate -s 20M "$READS_MAIN/data/big/table.jsonl"
  truncate -s 300M "$READS_MAIN/data/big/huge.csv"
  printf '# summary\n' >"$READS_MAIN/data/big/DIGEST.md"
  git -C "$READS_WT" init -q -b fm/wt-task
  printf 'x\n' >"$READS_WT/notes.md"
}

reads_gate() {  # <args...>: both rules in log mode, no inherited task or home attribution
  HOME="$READS_HOME" LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log env -u FM_TASK_ID -u FM_HOME "$GATE" "$@"
}

field() {  # <row> <js expression over r>
  node -e 'const r = JSON.parse(process.argv[1]); process.stdout.write(String(eval(process.argv[2])))' "$1" "$2"
}

all_rows() {  # every read log, oldest day first
  cat "$READS_STATE"/reads-*.jsonl 2>/dev/null
}

last_row() {
  all_rows | tail -n 1
}

rows() {
  all_rows | wc -l | tr -d ' '
}

test_claude_read_tool() {
  local row payload out
  payload=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:"data/big/lines.txt",offset:10,limit:100}}))' "$READS_MAIN")
  out=$(printf '%s' "$payload" | reads_gate --harness claude 2>&1)
  expect_code 0 $? "a Read call is allowed"
  assert_equals "" "$out" "a Read call prints nothing"
  row=$(last_row)
  assert_equals "claude|s1|$READS_MAIN|$READS_MAIN/data/big/lines.txt|3893|true|false|100|true" \
    "$(field "$row" '[r.harness, r.session, r.home, r.path, r.size, r.bounded, r.whole_file, r.lines, r.bytes_estimated].join("|")')" \
    "a line-bounded Read records harness, session, home, path, size and bounds"
  assert_equals 389 "$(field "$row" 'r.bytes_requested')" "100 lines become bytes from the file's own bytes per line"
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:process.argv[1]+"/data/big/table.jsonl"}}))' "$READS_MAIN")
  printf '%s' "$payload" | reads_gate --harness claude
  row=$(last_row)
  assert_equals "20971520|0|true|false" "$(field "$row" '[r.bytes_requested, r.bytes_returned_est, r.whole_file, r.size_rule_would_block].join("|")')" \
    "an unbounded Read requests the whole file, and Claude returns nothing above 256 KB"
  assert_present "$READS_STATE/reads-$(date +%F).jsonl" "reads go to the day's read log"
  pass "the Claude Read tool is logged, allowed and silent"
}

test_returned_bytes_and_size_rule() {  # table: <harness> <path> [limit] => <requested>|<returned>|<size rule would block>
  local line harness path limit expected
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    expected=${line#*=> }
    read -r harness path limit <<<"${line%% =>*}"
    reads_gate --harness "$harness" --cwd "$READS_MAIN" --tool read --path "$path" ${limit:+--limit "$limit"}
    assert_equals "$expected" "$(field "$(last_row)" '[r.bytes_requested, r.bytes_returned_est, r.size_rule_would_block].join("|")')" \
      "$harness Read of $path${limit:+ limit $limit}"
  done <<'EOF'
claude data/big/lines.txt => 3893|3893|false
claude data/big/huge.csv => 314572800|0|true
claude data/big/huge.csv 1 => 65536|65536|false
pi data/big/lines.txt => 3893|3893|false
pi data/big/table.jsonl => 20971520|51200|false
opencode data/big/huge.csv => 314572800|131072000|true
EOF
  reads_gate --harness pi --cwd "$READS_MAIN" --command 'tail -n +2 data/big/huge.csv'
  assert_equals "314572800|true|false" "$(field "$(last_row)" '[r.bytes_requested, r.whole_file, r.size_rule_would_block].join("|")')" \
    "a tail to the end of a file over the limit is a whole-file read the size rule does not refuse"
  reads_gate --harness pi --cwd "$READS_MAIN" --command 'cat data/big/huge.csv'
  assert_equals "314572800|true|true" "$(field "$(last_row)" '[r.bytes_requested, r.whole_file, r.size_rule_would_block].join("|")')" \
    "a cat of a file over the limit is one the size rule refuses"
  ln -sfn big "$READS_MAIN/data/linked"
  reads_gate --harness pi --cwd "$READS_MAIN/data/linked" --command 'cat huge.csv'
  assert_equals "$READS_MAIN/data/linked/huge.csv|true" "$(field "$(last_row)" '[r.path, r.size_rule_would_block].join("|")')" \
    "a read through a symlink carries the size rule's verdict on the real file"
  reads_gate --harness pi --cwd "$READS_MAIN" --command 'nice -n 19 ionice -c3 cat data/big/huge.csv'
  assert_equals "true|false" "$(field "$(last_row)" '[r.whole_file, r.size_rule_would_block].join("|")')" \
    "a niced whole-file read is one the size rule lets through"
  LATTICE_DATA_GATE_SIZE_LIMIT=400M reads_gate --harness pi --cwd "$READS_MAIN" --command 'cat data/big/huge.csv'
  assert_equals false "$(field "$(last_row)" 'r.size_rule_would_block')" "the configured size limit is the rule's"
  pass "Read rows estimate the harness-capped bytes returned and carry the size rule's decision"
}

test_shell_reads() {  # table: <command> => <tool:path-suffix:bytes_requested,...>
  local before line cmd expected got
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cmd=${line%% =>*}
    expected=${line#*=>}
    expected=${expected# }
    before=$(rows)
    reads_gate --harness pi --cwd "$READS_MAIN" --command "$cmd" || fail "a read command must be allowed: $cmd"
    got=$(all_rows | tail -n "+$((before + 1))" | node -e '
      const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean).map(JSON.parse);
      process.stdout.write(lines.map((r) => `${r.tool}:${r.path.split("/").slice(-2).join("/")}:${r.bytes_requested}`).join(","));')
    assert_equals "$expected" "$got" "rows for: $cmd"
  done <<'EOF'
cat data/big/lines.txt => cat:big/lines.txt:3893
head -c 100 data/big/table.jsonl => head:big/table.jsonl:100
head -n 5 data/big/lines.txt => head:big/lines.txt:19
tail -3 data/big/lines.txt => tail:big/lines.txt:12
tail -n -3 data/big/lines.txt => tail:big/lines.txt:12
tail -n +2 data/big/lines.txt => tail:big/lines.txt:3893
tail -c +5 data/big/lines.txt => tail:big/lines.txt:3893
head -n -5 data/big/lines.txt => head:big/lines.txt:3893
head --lines=-5 data/big/lines.txt => head:big/lines.txt:3893
head data/big/lines.txt => head:big/lines.txt:39
cat data/big/lines.txt | head -c 7 => cat:big/lines.txt:7
grep foo data/big/lines.txt | head -n 5 => grep:big/lines.txt:19
cat data/big/lines.txt | head -n -5 => cat:big/lines.txt:3893
sort -u data/big/lines.txt | head => sort:big/lines.txt:3893
wc -l data/big/lines.txt | head -1 => wc:big/lines.txt:3893
sha256sum data/big/lines.txt | head -c 64 => sha256sum:big/lines.txt:3893
nice -n 19 ionice -c3 wc -l data/big/lines.txt => wc:big/lines.txt:3893
grep -n foo data/big/lines.txt data/big => grep:big/lines.txt:3893
grep -e foo data/big/lines.txt => grep:big/lines.txt:3893
rg -g '*.txt' foo data/big/lines.txt => rg:big/lines.txt:3893
sed -n '1,5p' data/big/lines.txt => sed:big/lines.txt:3893
awk -F, '{print $1}' data/big/lines.txt => awk:big/lines.txt:3893
jq --arg a b . data/big/DIGEST.md => jq:big/DIGEST.md:10
python3 -c "print(open('data/big/lines.txt').read())" => python3:big/lines.txt:3893
wc -l < data/big/lines.txt => redirect:big/lines.txt:3893
head -n 5 < data/big/lines.txt => redirect:big/lines.txt:19
tail -n +2 < data/big/lines.txt => redirect:big/lines.txt:3893
grep foo < data/big/lines.txt | head -n 5 => redirect:big/lines.txt:19
sort < data/big/lines.txt | head -n 5 => redirect:big/lines.txt:3893
head -n 5 data/big/DIGEST.md 3< data/big/lines.txt => redirect:big/lines.txt:3893,head:big/DIGEST.md:10
grep x data/big/DIGEST.md 3< data/big/lines.txt | head -n 1 => redirect:big/lines.txt:3893,grep:big/DIGEST.md:10
cd data/big && cat DIGEST.md => cat:big/DIGEST.md:10
bash -c 'cat ~/Tools/firstmate/data/big/lines.txt' => cat:big/lines.txt:3893
cat data/big/missing.txt =>
cat data/big =>
cat data/big/*.txt =>
ls data/big =>
echo hello =>
EOF
  pass "shell read commands record each named file with its requested bytes"
}

test_digest_flag_and_attribution() {
  local row
  reads_gate --harness pi --cwd "$READS_WT" --command 'cat notes.md'
  row=$(last_row)
  assert_equals "wt-task|$READS_MAIN|false" "$(field "$row" '[r.task, r.home, r.is_digest].join("|")')" \
    "a worktree read takes its task from the fm/ branch and its home from that task's status file"
  HOME="$READS_HOME" FM_TASK_ID=env-task FM_HOME=/somewhere "$GATE" --harness pi --cwd "$READS_WT" --command 'cat notes.md'
  row=$(last_row)
  assert_equals "env-task|/somewhere" "$(field "$row" '[r.task, r.home].join("|")')" "FM_TASK_ID and FM_HOME win"
  reads_gate --harness opencode --cwd "$READS_MAIN" --tool read --path data/big/DIGEST.md --limit 20
  row=$(last_row)
  assert_equals "opencode|true|true" "$(field "$row" '[r.harness, r.is_digest, r.bounded].join("|")')" "a DIGEST.md read through --tool read is flagged"
  pass "digest reads are flagged and reads are attributed to a home and task"
}

test_never_blocks() {
  local before out today
  before=$(rows)
  out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/"}}' | HOME="$READS_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness claude 2>&1)
  expect_code 0 $? "a Read of a directory is allowed in enforce mode"
  assert_equals "" "$out" "and prints nothing"
  LATTICE_DATA_GATE_READS=off reads_gate --harness pi --cwd "$READS_MAIN" --command 'cat data/big/lines.txt'
  assert_equals "$before" "$(rows)" "LATTICE_DATA_GATE_READS=off logs nothing"
  HOME="$READS_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$READS_MAIN" --command 'cat data/big/lines.txt; rg foo' >/dev/null 2>&1
  expect_code 2 $? "a scan in the same command is still refused in enforce mode"
  assert_equals "$((before + 1))" "$(rows)" "and its read is still logged"
  today="$READS_STATE/reads-$(date +%F).jsonl"
  mv "$today" "$today.keep"
  mkdir "$today"
  out=$(reads_gate --harness pi --cwd "$READS_MAIN" --command 'cat data/big/lines.txt' 2>&1)
  expect_code 0 $? "an unwritable read log still allows"
  assert_equals "" "$out" "and prints nothing"
  rmdir "$today"
  mv "$today.keep" "$today"
  pass "the read log never blocks, never prints, and can be turned off"
}

epoch_of() {  # <local date> <HH:MM>
  date -d "$1 $2" +%s
}

iso_of() {  # <local date> <HH:MM>
  date -u -d "@$(epoch_of "$1" "$2")" +%Y-%m-%dT%H:%M:%SZ
}

test_report() {
  local h="$READS_ROOT/rhome" day prev next state out relay md big="/d/big" small="/d/small" old kept
  day=$(date -d '-3 days' +%F)
  prev=$(date -d "$day -1 day" +%F)
  next=$(date -d "$day +1 day" +%F)
  old=$(date -d '-61 days' +%F)
  kept=$(date -d '-59 days' +%F)
  state="$h/.local/state/lattice-data-gate"
  mkdir -p "$state" "$h/base"
  row() {  # <date> <time> <session> <path> <size> <bytes> [digest] [whole] [returned]
    printf '{"ts":"%s","harness":"claude","session":"%s","task":"t1","cwd":"/d","tool":"Read","path":"%s","size":%s,"bytes_requested":%s,"bytes_returned_est":%s,"is_digest":%s,"whole_file":%s,"size_rule_would_block":%s}\n' \
      "$(iso_of "$1" "$2")" "$3" "$4" "$5" "$6" "${9:-$6}" "${7:-false}" "${8:-true}" "$([ "${8:-true}" = true ] && [ "$5" -gt 200000000 ] && echo true || echo false)"
  }
  {
    row "$day" 09:00 s1 "$big/DIGEST.md" 100 100 true
    row "$day" 09:10 s1 "$big/table.jsonl" 50000000 1000 false false
    row "$day" 10:00 s2 "$big/DIGEST.md" 100 100 true
    row "$day" 10:05 s2 "$small/other.jsonl" 50000000 50000000
    row "$day" 11:00 s3 "$big/DIGEST.md" 100 100 true
    row "$day" 11:50 s3 "$big/table.jsonl" 300000000 300000000 false true 0
    row "$day" 12:00 s4 "$big/DIGEST.md" 100 100 true
    row "$day" 12:05 s5 "$big/table.jsonl" 50000000 2000 false false
    row "$day" 23:50 s6 "$big/DIGEST.md" 100 100 true
  } >"$state/reads-$day.jsonl"
  {
    row "$next" 00:10 s6 "$big/table.jsonl" 50000000 50000000
    row "$next" 09:00 s7 "$big/table.jsonl" 50000000 50000000
  } >"$state/reads-$next.jsonl"
  printf '{"ts":"%s","harness":"pi","session":null,"task":null,"cwd":"/d","tool":"cat","path":"/d/prev.txt","size":9,"bytes_requested":9,"whole_file":true}\n' "$(iso_of "$prev" 12:00)" \
    >"$state/reads-$prev.jsonl"
  : >"$state/reads-$old.jsonl"
  : >"$state/reads-$kept.jsonl"
  {
    printf '{"ts":"%s","verdict":"block","would_block":true,"mode":"enforce","targets":[]}\n' "$(iso_of "$day" 09:00)"
    printf '{"ts":"%s","verdict":"allow","would_block":true,"mode":"log","targets":[]}\n' "$(iso_of "$day" 09:30)"
    printf '{"ts":"%s","verdict":"allow","would_block":false,"mode":"log","targets":[]}\n' "$(iso_of "$day" 10:00)"
    printf '{"ts":"%s","verdict":"allow","would_block":true,"would_block_rules":["size"],"mode":"enforce","size_mode":"log","targets":[{"rule":"size","size":314572800,"verdict":"block"}]}\n' "$(iso_of "$day" 10:30)"
    printf '{"ts":"%s","verdict":"block","would_block":true,"would_block_rules":["size"],"mode":"log","size_mode":"enforce","targets":[{"rule":"size","size":314572800,"verdict":"block"}]}\n' "$(iso_of "$day" 10:45)"
    printf '{"ts":"%s","verdict":"allow","would_block":false,"error":"node not found"}\n' "$(iso_of "$day" 11:00)"
    printf '{"ts":"%s","verdict":"block","would_block":true,"mode":"enforce","targets":[]}\n' "$(iso_of "$next" 09:00)"
  } >"$state/decisions.jsonl"
  printf '{"ts":"%s","verdict":"block","would_block":false,"error":"policy timed out after 6s (exit 124)","timeout":true}\n' "$(iso_of "$day" 08:00)" \
    >"$state/decisions-${day}T080000.jsonl"
  : >"$state/decisions-${old}T000000.jsonl"
  : >"$state/decisions-${kept}T000000.jsonl"
  {
    printf '{"ts":%s,"io_some_avg60":4.0,"io_full_avg60":1.0,"memory_some_avg60":2.0,"memory_full_avg60":0.5,"root_used":1000000000,"mntc_used":5000000000,"disk_read_bytes":100,"disk_write_bytes":1000000000}\n' "$(epoch_of "$day" 00:05)"
    printf '{"ts":%s,"io_some_avg60":8.0,"io_full_avg60":3.0,"memory_some_avg60":4.0,"memory_full_avg60":1.5,"root_used":2500000000,"mntc_used":5000000000,"disk_read_bytes":300,"disk_write_bytes":3000000000}\n' "$(epoch_of "$day" 12:00)"
    printf '{"ts":%s,"io_some_avg60":6.0,"io_full_avg60":2.0,"memory_some_avg60":3.0,"memory_full_avg60":1.0,"root_used":3000000000,"mntc_used":4000000000,"disk_read_bytes":50,"disk_write_bytes":500000000}\n' "$(epoch_of "$day" 23:55)"
  } >"$state/samples.jsonl"
  printf '# Baseline\n\n**Headline: agents requested on average 2.2 GB of file reads per day** (details).\n' >"$h/base/report.md"

  out=$(HOME="$h" "$REPORT" --date "$day" --baseline "$h/base/report.md")
  expect_code 0 $? "the report runs"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the report prints exactly one relay line"
  relay="Data gate $day: agents read 350 MB in 9 reads (est. returned 50.0 MB; largest 300 MB table.jsonl); scans would-block 2, blocked 1; size would-block 2, blocked 1; >200 MB whole-file reads 1; digests 5 read, hit rate 60%; disk root +2.0 GB, /mnt/c -1.0 GB, written 2.0 GB; IO PSI some 6.0% full 2.0%; baseline 2.2 GB of file reads per day"
  assert_equals "$relay" "$out" "the relay line carries bytes requested and returned, largest read, blocks, digest hit rate, disk and PSI"
  md="$state/reports/$day.md"
  assert_present "$md" "the report file is written under the gate's state dir"
  assert_grep "| DIGEST.md reads | 5: 3 hit, 2 miss" "$md" "a same-session big read in the digest's folder inside the window, even past midnight, is a miss"
  assert_grep "| Bytes returned (est., harness Read caps) | 50.0 MB |" "$md" "the harness-capped estimate is shown beside bytes requested"
  assert_grep "| Gate errors (allowed) | 1 |" "$md" "gate errors are counted"
  assert_grep "| Gate timeouts (refused) | 1 |" "$md" "a refused timeout in a rotated decision log is counted"
  assert_grep "| Baseline (before) | agents requested on average 2.2 GB of file reads per day |" "$md" "the baseline headline is included"
  assert_grep "- 300 MB Read /d/big/table.jsonl (claude, t1)" "$md" "the largest reads are listed"
  [ "$(wc -l <"$md")" -le 30 ] || fail "the report fits one screen"
  assert_absent "$state/reads-$old.jsonl" "a read log older than 60 days is deleted"
  assert_present "$state/reads-$kept.jsonl" "a read log inside 60 days is kept"
  assert_absent "$state/decisions-${old}T000000.jsonl" "a rotated decision log older than 60 days is deleted"
  assert_present "$state/decisions-${kept}T000000.jsonl" "a rotated decision log inside 60 days is kept"
  assert_present "$state/decisions.jsonl" "a decision log under the size limit is not rotated"
  HOME="$h" LATTICE_DATA_GATE_DECISIONS_MAX_BYTES=100 "$REPORT" --date "$day" --baseline "$h/none" >/dev/null
  assert_absent "$state/decisions.jsonl" "a decision log over the size limit is rotated"
  [ "$(find "$state" -maxdepth 1 -name 'decisions-*T*.jsonl' | wc -l | tr -d ' ')" -eq 3 ] || fail "the rotated decision log sits beside the earlier ones"
  out=$(HOME="$h" "$REPORT" --date "$day" --baseline "$h/none")
  assert_contains "$out" "scans would-block 2, blocked 1" "the next report still reads the rotated decision log"
  out=$(HOME="$h" LATTICE_DATA_GATE_READS_KEEP_DAYS=30 "$REPORT" --date "$day" --baseline "$h/none")
  assert_not_contains "$out" "baseline" "an absent baseline is left out"
  assert_absent "$state/reads-$kept.jsonl" "LATTICE_DATA_GATE_READS_KEEP_DAYS shortens the retention"
  assert_present "$state/reads-$day.jsonl" "the reported day's log is kept"
  out=$(HOME="$READS_ROOT/empty" "$REPORT" --date "$day")
  assert_equals "Data gate $day: agents read 0 B in 0 reads (est. returned 0 B; none); scans would-block 0, blocked 0; size would-block 0, blocked 0; >200 MB whole-file reads 0; digests 0 read, hit rate n/a; no disk/PSI samples" \
    "$out" "missing inputs report as empty"
  HOME="$h" "$REPORT" --date 20-09-2026 >/dev/null 2>&1
  expect_code 1 $? "a malformed date is refused"
  for flag in --today --no-write --digest-window-min; do
    HOME="$h" "$REPORT" "$flag" >/dev/null 2>&1
    expect_code 1 $? "$flag is not an option"
  done
  pass "the daily report summarizes reads, decisions, digests, disk and PSI for one local day"
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
test_measure_logs_why
test_timeout_refuses_enforced_calls
test_roots_built_lazily
build_size_fixture
test_size_bash_table
test_size_read_table
test_size_refusal_and_modes
test_size_read_payload_transports
test_size_internal_error_allows

# The installer cases see the fake systemctl first on PATH; the subshell keeps
# that PATH and FAKE_SYSTEMCTL_LOG away from every other case.
(
  export FAKE_SYSTEMCTL_LOG="$INSTALL_ROOT/systemctl.log"
  export PATH="$INSTALL_FAKEBIN:$PATH"
  test_dry_run_writes_nothing
  test_install_merges_and_backs_up
  test_reinstall_is_idempotent
  test_uninstall_restores_bytes
  test_generated_bulk_paths_feed_gate_and_ignores
  test_reinstall_after_edit_keeps_edits
  test_uninstall_after_edit_strips_only_gate
  test_unparseable_settings_left_untouched
  test_only_existing_harnesses
  test_installed_adapters_call_the_gate
  test_installed_adapters_log_reads
  test_reinstall_upgrades_old_claude_matcher
  test_codex_trust_and_status
  test_report_timer
) || exit 1

build_reads_fixture
test_claude_read_tool
test_returned_bytes_and_size_rule
test_shell_reads
test_digest_flag_and_attribution
test_never_blocks
test_report
