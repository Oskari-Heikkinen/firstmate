// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname } from "node:path";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M395280RBV9FN0GB892PQ7FP/bin/fm-busy-event.sh", [
      "apply", "/tmp/fm-nested-lab.W8QNh9/home/state", "nest1", state,
      "--gen", "g1790236319.3475487.27427", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => execFile("touch", ["/tmp/fm-nested-lab.W8QNh9/home/state/nest1.turn-ended"]));
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M395280RBV9FN0GB892PQ7FP/bin/fm-busy-event.sh", [
      "progress", "/tmp/fm-nested-lab.W8QNh9/home/state", "nest1", "--gen", "g1790236319.3475487.27427",
    ]);
  });
  // This worktree lies inside a firstmate home; drop that home's own
  // instruction files from the system prompt so the worker never carries the
  // supervisor contract its launch brief tells it not to follow.
  const nestedHome = "/tmp/fm-nested-lab.W8QNh9/home";
  const canonicalDir = (file: string) => {
    try { return realpathSync(dirname(file)); } catch { return dirname(file); }
  };
  pi.on("before_agent_start", (event: any) => {
    const files = event?.systemPromptOptions?.contextFiles;
    if (!Array.isArray(files) || typeof event.systemPrompt !== "string") return;
    let prompt: string = event.systemPrompt;
    for (const file of files) {
      if (!file || typeof file.path !== "string") continue;
      if (canonicalDir(file.path) !== nestedHome) continue;
      const block = "<project_instructions path=\"" + file.path + "\">\n" + file.content + "\n</project_instructions>\n\n";
      const at = prompt.indexOf(block);
      if (at !== -1) prompt = prompt.slice(0, at) + prompt.slice(at + block.length);
    }
    if (prompt !== event.systemPrompt) return { systemPrompt: prompt };
  });
}
