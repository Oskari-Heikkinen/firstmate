#!/usr/bin/env bash
# Owner automation behavior and guard fixtures; CI only. Runtime and protocol
# expectations are in docs/owner-notice.md. No live home, watcher or backend.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-owner-notice-watch)
HELPER="$ROOT/tests/lib/owner_notice_watch.py"
SHIM=0
if [ "$(uname -s)" = Linux ] && command -v cc >/dev/null 2>&1 && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
  cc -shared -fPIC -o "$TMP_ROOT/stat-block.so" "$ROOT/tests/lib/owner-notice-stat-block.c" -ldl || fail 'compile stat-block shim'
  mkdir "$TMP_ROOT/control"
  mkfifo "$TMP_ROOT/control/fifo"
  rc=0
  # shellcheck disable=SC2016 # $1 belongs to the isolated child shell.
  BLOCK_PREFIX="$TMP_ROOT/control/path" BLOCK_HITS="$TMP_ROOT/control/hits" BLOCK_FIFO="$TMP_ROOT/control/fifo" \
    LD_PRELOAD="$TMP_ROOT/stat-block.so" timeout 3 bash -c '[ "$1" -nt /x ]' _ "$TMP_ROOT/control/path" || rc=$?
  expect_code 124 "$rc" 'stat shim positive control'
  [ -s "$TMP_ROOT/control/hits" ] || fail 'stat shim missed the positive control'
  SHIM=1
fi

behavior() { python3 "$HELPER" "$ROOT" "$TMP_ROOT" "$1" || fail "owner-notice automation: $1"; }
shim_behavior() {
  if [ "$SHIM" -eq 0 ]; then echo 'SKIP: stat fault fixtures require Linux/glibc and cc'; return 0; fi
  behavior "$1"
}
case_idle() { behavior idle; }
case_handrun() { behavior handrun; } # R-U2-10
case_stat_stall() { shim_behavior stat_stall; } # R-U2-03
case_stage_stall() { shim_behavior stage_stall; }
case_stage_live_signal() { shim_behavior stage_live_signal; } # R-U2-04
case_adoption() { shim_behavior adoption; } # R-U2-05, R-U2-17
case_watcher_loss() { behavior watcher_loss; } # R-U2-09
case_foreground() { shim_behavior foreground; } # R-U2-27
case_flapping() { shim_behavior flapping; } # R-U2-28, R-U2-30(stat)
case_exit_term() { shim_behavior exit_term; } # R-U2-16(a)
case_exit_kill() { shim_behavior exit_kill; } # R-U2-16(b)
case_pdeath() { shim_behavior pdeath_ingest; } # R-U2-19
case_survival_bind() { shim_behavior survival_bind; } # R-U2-29
case_survival_retire() { shim_behavior survival_retire; } # R-U2-29
case_survival_ingest() { shim_behavior survival_ingest; } # R-U2-29
case_foreground_recovery() { shim_behavior foreground_recovery; } # R-U2-30(fg)
case_stage_deadline() { behavior stage_deadline; } # R-U2-26(a,b,c)
case_stage_signal() { behavior stage_signal; } # R-U2-26(d), R5-n2
case_ingest_deadline() { behavior ingest_deadline; } # R-U2-18(a,b,c)
case_ingest_signal() { behavior ingest_signal; } # R-U2-18(d), R5-n2
case_backoff() { behavior backoff; } # R-U2-20, R-U2-21
case_slow_sweep() { behavior slow_sweep; }
case_cap() { behavior cap; } # R-U2-07
case_racy() { behavior racy; } # R-U2-08
case_all_ingests_stalled() { behavior all_ingests_stalled; } # independent projector slot
case_projection_restart() { behavior projection_restart; } # root stall reader and adoption
case_stage_recovery() { behavior stage_recovery; } # R-U2-30(stage)
case_ingest_recovery() { behavior ingest_recovery; } # R-U2-30(ingest)
case_singleton() { behavior singleton; } # R-U2-11
case_in_flight() { behavior in_flight; } # R-U2-22
case_handover() { behavior handover; } # R-U2-23
case_busy() { behavior busy; } # R-U2-24
case_start_announce() { behavior start_announce; } # R-U2-25
case_cross_role() { shim_behavior pdeath_bind; } # R-U2-29 role mismatch
case_stale_transition() { behavior stale_transition; } # R-U2-12(a,d)
case_first_start() { behavior first_start; } # R-U2-12(f)
case_successor_grace() { behavior successor_grace; } # R-U2-12(b,e)
case_recovery_down() { behavior recovery_down; } # R-U2-12(c)
case_live_fast() { behavior live_fast; } # R-U2-02(ii)
case_old_projection_failure() { behavior old_projection_failure; }
case_old_projection_stale() { behavior old_projection_stale; }
case_role_failure_retention() { behavior role_failure_retention; }
case_role_failure_scope() { behavior role_failure_scope; }
case_quarantine_children() { behavior quarantine_children; }
case_quarantine_stall() { behavior quarantine_stall; }
case_quarantine_automation() { behavior quarantine_automation; }
case_quarantine_seen() { behavior quarantine_seen; }
case_quarantine_index() { behavior quarantine_index; }
case_quarantine_binding() { behavior quarantine_binding; }
case_quarantine_route() { behavior quarantine_route; }
case_quarantine_live() { behavior quarantine_live; }
case_quarantine_routing() { behavior quarantine_routing; }
case_quarantine_foreground() { behavior quarantine_foreground; }
case_quarantine_projection() { behavior quarantine_projection; }
case_quarantine_root_stall() { behavior quarantine_root_stall; }
case_quarantine_ledger() { behavior quarantine_ledger; }
case_quarantine_stat_reply() { behavior quarantine_stat_reply; }
case_empty_after_projection_failure() { behavior empty_after_projection_failure; }
case_empty_after_failed_starts() { behavior empty_after_failed_starts; }
case_empty_incomplete_projection() { behavior empty_incomplete_projection; }
case_lifecycle_absent() { behavior lifecycle_absent; }
case_lifecycle_idle() { behavior lifecycle_idle; }
case_lifecycle_idle_native() { behavior lifecycle_idle_native; }
case_lifecycle_drained() { behavior lifecycle_drained; }
case_lifecycle_legacy_pending() { behavior lifecycle_legacy_pending; }
case_lifecycle_notice_unknown() { behavior lifecycle_notice_unknown; }
case_lifecycle_held_restart() { behavior lifecycle_held_restart; }
case_lifecycle_projection() { behavior lifecycle_projection; }
case_lifecycle_incomplete() { behavior lifecycle_incomplete; }
case_lifecycle_routing() { behavior lifecycle_routing; }
case_lifecycle_ownership() { behavior lifecycle_ownership; }
case_lifecycle_counter() { behavior lifecycle_counter; }
case_lifecycle_stalled() { behavior lifecycle_stalled; }
case_lifecycle_restart_failed() { behavior lifecycle_restart_failed; }
case_publication_fifo() { behavior publication_fifo; }
case_publication_stale_counter() { behavior publication_stale_counter; }
case_publication_two_clears() { behavior publication_two_clears; }
case_publication_third_failure() { behavior publication_third_failure; }
case_publication_failure() { behavior publication_failure; }
case_publication_deadline() { behavior publication_deadline; }
case_publication_store() { behavior publication_store; }
case_publication_admission() { behavior publication_admission; }
case_publication_runtime() { behavior publication_runtime; }
case_publication_limits() { behavior publication_limits; }
case_publication_reader() { behavior publication_reader; }
case_publication_frozen_reader() { behavior publication_frozen_reader; }
case_publication_lifetime() { behavior publication_lifetime; }
case_publication_watcher_deadline() { behavior publication_watcher_deadline; }
case_publication_result_reader() { behavior publication_result_reader; }
case_publication_advance_failure() { behavior publication_advance_failure; }
case_publication_cursor_replay() { behavior publication_cursor_replay; }
case_publication_initialization() { behavior publication_initialization; }
case_publication_initialization_dead() { behavior publication_initialization_dead; }
case_publication_metadata_directory() { behavior publication_metadata_directory; }
case_automation_reader() { behavior automation_reader; }
case_runtime_empty() { behavior runtime_empty; }
case_runtime_work() { behavior runtime_work; }
case_runtime_pending() { behavior runtime_pending; }
case_runtime_unknown() { behavior runtime_unknown; }
case_runtime_api() { behavior runtime_api; }
case_runtime_sqlite_missing() { behavior runtime_sqlite_missing; }
case_runtime_probe_error() { behavior runtime_probe_error; }
case_runtime_manual() { behavior runtime_manual; }
case_runtime_changed() { behavior runtime_changed; }
case_start_authority() { behavior start_authority; }
case_start_authority_alias() { behavior start_authority_alias; }
case_start_authority_bound() { behavior start_authority_bound; }
case_runtime_first_publish() { behavior runtime_first_publish; }
case_runtime_restart() { behavior runtime_restart; }
case_runtime_overlap() { behavior runtime_overlap; }
case_runtime_native_failure() { behavior runtime_native_failure; }
case_runtime_native_paths() { behavior runtime_native_paths; }
case_recovery_reader() { behavior recovery_reader; }
case_recovery_progress() { behavior recovery_progress; }
case_recovery_prior_config_work() { behavior recovery_prior_config_work; }
case_recovery_prior_config_empty() { behavior recovery_prior_config_empty; }
case_recovery_prior_reserve_work() { behavior recovery_prior_reserve_work; }
case_recovery_prior_reserve_empty() { behavior recovery_prior_reserve_empty; }
case_recovery_prior_write_work() { behavior recovery_prior_write_work; }
case_recovery_prior_write_empty() { behavior recovery_prior_write_empty; }
case_startup_config() { behavior startup_config; }
case_startup_reserve() { behavior startup_reserve; }
case_startup_exit_counter() { behavior startup_exit_counter; }
case_startup_exit_write() { behavior startup_exit_write; }
case_projection_reader() { behavior projection_reader; }
case_registration_notice() { behavior registration_notice; }
case_registration_runner() { behavior registration_runner; }
case_registration_status() { behavior registration_status; }
case_registration_directory() { behavior registration_directory; }
case_registration_late() { behavior registration_late; }
case_projection_failure() { behavior projection_failure; }
case_manual_batch_spoof() { behavior manual_batch_spoof; }
case_legitimate_batch() { behavior legitimate_batch; }
case_batch_authorization_unknown() { behavior batch_authorization_unknown; }
case_counter_reader() { behavior counter_reader; }
case_bad_routing() { behavior bad_routing; }
case_empty_home() { behavior empty_home; }
case_refusal_ack() { behavior refusal_ack; } # R-U2-13
case_history() { behavior history; } # R-U2-06
case_archive() { behavior archive; } # R-U2-15
case_retention_boundary() { behavior retention_boundary; } # no new manual retention front
case_bound_bind() { shim_behavior bound_bind; } # R-U2-14
case_bound_retire() { shim_behavior bound_retire; } # R-U2-14
case_bound_ingest() { shim_behavior bound_ingest; } # R-U2-14
case_real_watcher() { shim_behavior real_watcher; } # R-U2-01(a); U4 owns adapter companion
case_engine_death() { behavior engine_death; }
case_loop_death() { behavior loop_death; }
case_cost() {
  if ! command -v unshare >/dev/null 2>&1; then
    echo 'SKIP: namespace fork count requires unshare'; return 0
  fi
  if ! unshare -rpf --mount-proc true > "$TMP_ROOT/namespace-control" 2>&1; then
    printf 'SKIP: PID namespace unavailable: '; tr '\n' ' ' < "$TMP_ROOT/namespace-control"; echo
    return 0
  fi
  unshare -rpf --mount-proc bash "$ROOT/tests/lib/owner-notice-cost.sh" "$ROOT/bin" "$TMP_ROOT/cost" || fail 'namespace quiet and active-key fork costs'
}
case_active_keys() {
  local d="$TMP_ROOT/active" rc=0
  mkdir "$d"
  printf '{"schema":"fm-alert-store/v1","active":{"held":{}},"acks":{"held":{}},"events":[]}\n' > "$d/store"
  # Pure callable: no shell reader may treat an acknowledgement as absence.
  FM_STORE="$d/store" bash -c '. "$1"; fm_alert_store_active_keys "$FM_STORE"' _ "$ROOT/bin/fm-alert-store-lib.sh" > "$d/keys"
  assert_grep held "$d/keys" 'held key includes acknowledged level'
  printf '{"schema":"fm-alert-store/v1","active":{},"acks":{},"events":[]}\n' > "$d/store"
  FM_STORE="$d/store" bash -c '. "$1"; fm_alert_store_active_keys "$FM_STORE"' _ "$ROOT/bin/fm-alert-store-lib.sh" > "$d/keys" || fail 'healthy empty set'
  [ ! -s "$d/keys" ] || fail 'empty set printed keys'
  printf '{}\n' > "$d/store"
  FM_STORE="$d/store" bash -c '. "$1"; fm_alert_store_active_keys "$FM_STORE"; rc=$?; [ "$rc" = 1 ] && [ -n "$FM_ALERT_PROBLEM" ]' _ "$ROOT/bin/fm-alert-store-lib.sh" || rc=$?
  expect_code 0 "$rc" 'invalid store is unknown, not empty'
}
# Isolated cases are deliberately serial so deadline observations do not share
# this suite's own load. The pool still collects every failure in one CI run.
fm_run_case_pool 1 "$TMP_ROOT/case-logs" \
  case_idle case_handrun case_stat_stall case_stage_stall case_adoption \
  case_watcher_loss case_foreground case_flapping case_active_keys \
  case_exit_term case_exit_kill case_pdeath case_survival_bind \
  case_survival_retire case_survival_ingest case_foreground_recovery \
  case_stage_deadline case_stage_signal case_ingest_deadline case_ingest_signal \
  case_backoff case_slow_sweep case_cap case_racy case_all_ingests_stalled \
  case_projection_restart case_stage_recovery case_ingest_recovery \
  case_singleton case_in_flight case_handover case_busy case_start_announce case_cross_role \
  case_stale_transition case_first_start case_successor_grace case_recovery_down case_live_fast case_cost case_engine_death case_loop_death \
  case_history case_archive case_retention_boundary case_bound_bind case_bound_retire case_bound_ingest case_real_watcher case_refusal_ack \
  case_stage_live_signal case_counter_reader case_bad_routing case_empty_home \
  case_projection_reader case_registration_notice case_registration_runner case_registration_status case_registration_directory case_registration_late \
  case_projection_failure case_manual_batch_spoof case_legitimate_batch case_batch_authorization_unknown \
  case_old_projection_failure case_old_projection_stale case_role_failure_retention case_role_failure_scope case_automation_reader \
  case_quarantine_children case_quarantine_stall case_quarantine_automation case_quarantine_seen \
  case_quarantine_index case_quarantine_binding case_quarantine_route case_quarantine_live \
  case_quarantine_routing case_quarantine_foreground case_quarantine_projection case_quarantine_root_stall \
  case_quarantine_ledger case_quarantine_stat_reply case_empty_after_projection_failure case_empty_after_failed_starts \
  case_empty_incomplete_projection \
  case_lifecycle_absent case_lifecycle_idle case_lifecycle_drained case_lifecycle_held_restart \
  case_lifecycle_projection case_lifecycle_incomplete case_lifecycle_routing case_lifecycle_ownership \
  case_lifecycle_stalled case_lifecycle_restart_failed case_lifecycle_counter case_lifecycle_idle_native \
  case_lifecycle_legacy_pending case_lifecycle_notice_unknown \
  case_publication_fifo case_publication_stale_counter case_publication_two_clears \
  case_publication_third_failure case_publication_failure case_publication_deadline case_publication_reader \
  case_runtime_empty case_runtime_work case_runtime_pending case_runtime_unknown \
  case_runtime_api case_runtime_sqlite_missing case_runtime_probe_error case_runtime_manual case_runtime_changed \
  case_start_authority case_start_authority_alias case_start_authority_bound case_runtime_first_publish \
  case_runtime_restart case_runtime_overlap case_runtime_native_failure case_runtime_native_paths \
  case_startup_config case_startup_reserve case_startup_exit_counter case_startup_exit_write \
  case_recovery_reader case_recovery_progress \
  case_recovery_prior_config_work case_recovery_prior_config_empty \
  case_recovery_prior_reserve_work case_recovery_prior_reserve_empty \
  case_recovery_prior_write_work case_recovery_prior_write_empty \
  case_publication_store case_publication_admission case_publication_runtime case_publication_limits \
  case_publication_frozen_reader case_publication_lifetime case_publication_watcher_deadline \
  case_publication_result_reader case_publication_advance_failure case_publication_cursor_replay \
  case_publication_initialization case_publication_initialization_dead case_publication_metadata_directory
