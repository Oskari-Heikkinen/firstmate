# Pi and Pi-signed

The combined contract is genuine: Pi and the signed wrapper expose the same verified CLI and TUI behavior.
Verified on 2026-07-27 with Pi and Pi-signed 0.82.0 unless a fact gives another version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` marks busy and `agent_settled`, confirmed by `ctx.isIdle()`, marks idle; this covers retries, compaction, tool loops, and queued continuations. A `--compact-at` early compaction starts only after the `agent_settled` dispatch (verified on Pi 0.85.1), so a later extension's settle handler, Herdr's pane-status integration among them, still reads idle (`../../../docs/herdr-backend.md` "Early compaction and the native settle"). |
| Exit command | `/quit`. |
| Resume | `--session <path-or-id>` resumes that exact session, and creates it at that path when the file is gone. `../../../bin/fm-spawn.sh` passes it on a relaunch so a Herdr pane's already-bound status authority keeps applying (`../../../bin/fm-control-lib.sh`'s `fm_control_relaunch_resume_flag`; `../../../docs/herdr-backend.md` "Agent status authority and relaunch"). There is still no `resume` control verb. |
| Interrupt | Single Escape. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <model>`; under a home's worker account pin the model must be `<provider>/<id>` and Firstmate also passes `--provider <provider>` (`../../../docs/configuration.md` "Worker account pin"). A Claude model, and a launch with no model, always refuses ([Claude models never run on Pi](#claude-models-never-run-on-pi)). |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; both identities expose the same levels and completed the same model-qualified max-thinking smoke. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

Native Codex sessions may request `ultra` through the native extension flag described by `../../../bin/fm-spawn.sh`; it is separate from Pi's thinking levels.
Pi has no permission system, so workers are always autonomous.
Fullscreen can bury steering messages by rewriting scrollback, so Firstmate avoids it when the installed CLI supports the override.
`../../../bin/fm-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.

Pi-signed is the signed wrapper identity verified on version 0.82.0.
Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
The observed signed process tree has an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as the exact `pi-launcher` name for either selected executable.
The installed plain `pi` command also execs that signed launcher.
The router's Detection section owns how launch markers and ancestry select between the identities.

Keep the instructions as one positional argument.
Multiple positional arguments become separate queued messages; the spawn template already preserves the one-argument shape.

A project trust dialog can appear on the first Pi run in any not-yet-trusted directory that holds a trust-requiring resource such as `.pi/extensions/`, including a clean worktree and a freshly seeded secondmate home.
For an already-stalled launch, accept it with Enter only after verifying the selected choice is the task directory, never its parent, and verify the instructions begin processing.
A manual persistent decision is stored per path in `~/.pi/agent/trust.json`, or in the pinned root's `trust.json` under a worker account pin, so later spawns in the same pooled slot under that root skip it.
For unattended ships, scouts, and seeded secondmates, `../../../bin/fm-spawn.sh --help` owns the capability-gated project-trust approval mechanics; [runtime verification](../../../../../docs/verification/runtime-backends.md#pi-launch-project-trust) owns the regression evidence.
The composer owner's named blocking-dialog classification also reaches a stale Pi worker's wake reason rather than treating it as idle after a park nudge.
The same real-Pi guard checks worker-shaped copies, session-only approval scope, and composer/watch dialog naming from a live tmux viewport; the runtime verification record owns its evidence and limits.
It does not allocate a worker through fm-spawn, submit a brief, or exercise stale-wake scheduling/delivery.
Existing open-call, declared-wait, and hold bounds retain precedence: a worker already covered by one may remain on the dialog without a distinct dialog wake until that wait is inspected; dialog naming does not override those absorptions.

## Claude models never run on Pi

Pi bills Anthropic subscription use as per-token extra usage, so Claude work never runs through `pi` or `pi-signed`.
`../../../bin/fm-pi-model-guard-lib.sh` owns this enforced guard and its model-identity test.
It refuses a Claude model, naming the model and the reason, on every path that starts a Pi agent: spawn, ship, scout, restore, relaunch (before the old agent stops, so park resume and reboot relaunch too), local and remote secondmate launch, and dispatch-profile resolution.
It holds whether the model comes from a flag, a dispatch profile, the recorded relaunch model, `config/secondmate-harness`, or a raw Pi command's `--model`, `--models`, or `--provider anthropic`.
It needs no `config/pi-account` and never reads one; a pin that declares `anthropic` still refuses, and the pin's own provider check runs after it.
A model names Claude when any provider path segment is `anthropic`, or it holds one of the tokens claude, anthropic, opus, opusplan, sonnet, haiku, or fable, so `sonnet`, `opus[1m]`, `sonnet:high`, and Bedrock or gateway ids such as `us.anthropic.claude-...` all refuse.
`bin/fm-harness.sh validate-pi-model <harness> <model>` runs the same test.
A Pi launch must name its model: with no model, `default`, or a raw command without `--model` or `--models`, Pi would pick its own start model (a saved session model, its settings default, or the first signed-in provider's default), which can be Claude.
The guard refuses such a launch on the same paths, naming the reason and asking for an explicit non-Claude `--model <provider>/<id>`.
`config/crew-harness` carries no model, so a home whose crew harness is Pi passes `--model` on each spawn or names it in a dispatch profile; `config/secondmate-harness` takes it as its second token.

## Worker turn-end extension

`../../../bin/fm-spawn.sh` keeps the worker turn-end extension in `state/`, outside the worktree, because project-local extension files worsen the trust gate and pollute the project.
The extension listens for Pi's `turn_end` event, not `agent_end`, so supervision is notified after each completed turn rather than only when the whole run exits.
Native-harness progress uses the separate generation-bound marker owned by `../../../bin/fm-busy-event.sh`; it never fabricates Pi turn completion.
Pi sets `PI_CODING_AGENT=true` for its children as its harness-detection marker.

## Primary integration

The primary turn-end behavior was verified on 2026-07-09 with Pi 0.80.5.
`.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `../../../bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
On native Windows, the extension runs its session-start, both PreToolUse, turn-end, and operational-input Bash helpers through `bash`; macOS and Linux invoke those helpers directly.

The primary watcher protocol also requires `.pi/extensions/fm-primary-pi-watch.ts`.
The Pi engine auto-discovers both tracked project-local extensions once the project is trusted.
The model arms through the `fm_watch_arm_pi` tool, never through a foreground shell arm.
Native-harness adapters can discover the same guarded FirstMate tools and operational message allowlist through the public Pi event-bus contract in `.pi/extensions/lib/fm-native-contract.ts`; no Pi built-in tools cross that contract.
The tool result and clean-exit fallback are owned by `.pi/extensions/fm-primary-pi-watch.ts` and `../../../docs/watcher-continuity.md`.
`../../../bin/fm-session-start.sh` reports when the live Pi-family session has not loaded both extensions and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

When a secondmate is launched on Pi or Pi-signed, `../../../bin/fm-spawn.sh --secondmate` launches the selected executable with `-e .pi/extensions/fm-primary-turnend-guard.ts`, `-e .pi/extensions/fm-primary-pi-watch.ts`, and `-e` of the parent home's `state/<id>.pi-ext.ts` busy extension.
Both primary files already exist in the secondmate home's git worktree.
The busy extension lives outside that home, so Pi's project-trust gate does not see it, and its turn-end handler does not touch the parent's turn-ended marker.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the `tool_call` event.
