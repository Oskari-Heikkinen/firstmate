## 2. Layout and state

`docs/configuration.md` is the single owner of the operational-home layout and configuration schemas, and its "Layout reference" gives every tracked, private, and runtime path a one-line role and owner; each producing script's header and help own exact child fields and mutation mechanics.
`FM_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts continue to come from their tracked code root.
Each secondmate has a persistent isolated `FM_HOME`, including its own state, backlog, projects, and session lock.
`bin/fm-send.sh` fails closed unless `FM_HOME` is explicit, so a steer cannot silently resolve against another home.

Tracked files hold shared instructions and tooling; `data/` holds durable private fleet records; `state/` holds runtime records and append-only status events; `config/` holds local operating choices; and `projects/` contains clones that are read-only to firstmate except under hard rule 1's concrete captain-approved project operation exception.

Never hand-edit, move, or delete these runtime records under `state/`; only their owning scripts may write them:

- The session lock sidecar `.lock-session` (written only by `bin/fm-lock.sh`), the watcher recovery record `.watcher-down`, the durable wake queue `.wake-queue`, and the `.watch.lock` and `.wake-queue.lock` locks.
- Watcher internals: `.hash-*`, `.count-*`, `.stale-*`, `.stale-since-*`, `.churn-since-*`, `.paused-*`, `.wedge-escalations-*`, `.dead-reported-*`, `.writing-*`, `.waiting-*`, `.seen-*`, `.hb-surfaced-*`, `.last-*` (including the `.last-watcher-beat` liveness beacon), and `.heartbeat-streak`.
- Sub-supervisor internals `.subsuper-*` and `.supervise-daemon.*`.
- Claude Stop auto-arm records `.claude-autoarm*` and `.turnend-claude-blocks*`, and Cursor stop-hook records `.cursor-park-owner*` and `.turnend-cursor-blocks`.
- Every other record the layout reference names as written only by one script, such as `.afk-contract`, busy-state records, supervision leases, check trust bindings, `procevent/`, `when/`, `decision-bindings/`, `reconcile-requests/`, and the mail-plane cursors.

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory.

## 3. Session start (run once at every session start)
