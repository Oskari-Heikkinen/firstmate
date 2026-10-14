Supervision host: on for this home ([`supervision-host.md`](../supervision-host.md) owns the design); it runs in the arm's place, everything above still holds, and each `supervision-host:` line it adds says what that wake needs from you.
{claude,cursor} Attended, a headless supervision session takes the wakes the supervision branch may take, so routine outcomes never wake you.
{claude,cursor} `supervision-host: branch-outcome: ...`: run `bin/fm-wake-drain.sh` and process each entry of its `BRANCH OUTCOMES` section from the task's current state, because an entry can be old: your reply covers only entries still open, as if a settled one, such as a PR since merged, had never been listed; then run the `mark-processed` acknowledgement it prints.
{claude,cursor} A `supervision-host:` health note about repeated engine errors is the captain's to hear when it matters; handle the handed-back wake as usual.
{opencode,omp,grok,codex} Attended, every wake reaches you exactly as above.
{grok} `supervision-host: cycle boundary ...`: run `bin/fm-wake-drain.sh`, handle whatever it presents, run its printed acknowledgement, and re-arm the same background host call.
{grok} Keep the host command exactly the one background call above: never shell `&`, a pipe, or another command bundled onto it.
{codex} The host's park boundary returns as the checkpoint's ordinary `checkpoint: no actionable wake within <n>s` line; handle it as above.
{codex} While an away record exists each checkpoint uses the longer away bound (`FM_CODEX_WATCH_CHECKPOINT_AWAY`, default 3600s), so a captain message waits until the checkpoint returns unless the captain interrupts it.
While an away record exists the host hands each wake to a headless away session and a wake it hands back is automatic supervision, never the captain's return; the `afk` skill owns that posture.
