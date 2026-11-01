#!/usr/bin/env bash
# U3 consumer contract: isolated CLI fixtures for R-U3-01..09, adversarial
# presence reads, import closure, and acceptance of each pinned helper file.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "$(uname -s)" != Linux ]; then
  echo 'SKIP: owner-notice requires Linux /proc'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-owner-notice-interface)

interface_case() {
  python3 -B "$ROOT/tests/lib/owner-notice-interface.py" "$ROOT" "$TMP_ROOT" "$1" || fail "$1"
  pass "$1"
}

test_u3_01() { interface_case test_u3_01; }
test_u3_02() { interface_case test_u3_02; }
test_u3_03() { interface_case test_u3_03; }
test_u3_04() { interface_case test_u3_04; }
test_u3_05() { interface_case test_u3_05; }
test_u3_06() { interface_case test_u3_06; }
test_u3_07() { interface_case test_u3_07; }
test_u3_08() { interface_case test_u3_08; }
test_u3_09() { interface_case test_u3_09; }
test_readers() { interface_case test_readers; }
test_paths() { interface_case test_paths; }

test_consumer_pins() {
  local w="$TMP_ROOT/pins" file base rc sha
  mkdir -p "$w/repo/bin" "$w/decl" "$w/home/state"
  fm_git_identity fmtest fmtest@example.invalid
  fm_git_init_commit "$w/repo"
  for file in fm-owner-notice-client.py fm_owner_notice_format.py; do
    cp "$ROOT/bin/$file" "$w/repo/bin/$file"
  done
  git -C "$w/repo" add bin
  git -C "$w/repo" commit -qm 'fixture closure'
  {
    printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=fixture' 'owner=fixture-owner'
    for file in fm-owner-notice-client.py fm_owner_notice_format.py; do
      printf 'helper=%s/bin/%s\n' "$w/repo" "$file"
      sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$w/repo/bin/$file")
      printf 'accept=%s\n' "$sha"
    done
  } > "$w/decl/fixture.conf"
  for file in fm-owner-notice-client.py fm_owner_notice_format.py; do
    base=$(git -C "$w/repo" rev-parse HEAD)
    printf '\n# fixture byte change\n' >> "$w/repo/bin/$file"
    git -C "$w/repo" commit -qam "fixture changes $file"
    rc=0
    env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$w/home" FM_HELPER_CONSUMERS="$w/decl" \
      FM_HELPER_VERSIONS="$w/versions" bash "$ROOT/bin/fm-helper-consumers.sh" check-land \
      --repo "$w/repo" "$base" HEAD > "$w/out" 2>&1 || rc=$?
    expect_code 3 "$rc" "unaccepted $file must hold"
    assert_grep "$file" "$w/out" 'the held helper is named'
    sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$w/repo/bin/$file")
    printf 'accept=%s\n' "$sha" >> "$w/decl/fixture.conf"
    rc=0
    env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$w/home" FM_HELPER_CONSUMERS="$w/decl" \
      FM_HELPER_VERSIONS="$w/versions" bash "$ROOT/bin/fm-helper-consumers.sh" check-land \
      --repo "$w/repo" "$base" HEAD > "$w/out" 2>&1 || rc=$?
    expect_code 0 "$rc" "accepted $file must pass"
  done
  pass 'each closure file holds landing until accepted'
}

test_u3_01
test_u3_02
test_u3_03
test_u3_04
test_u3_05
test_u3_06
test_u3_07
test_u3_08
test_u3_09
test_readers
test_paths
test_consumer_pins
