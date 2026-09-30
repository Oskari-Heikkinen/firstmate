// Read-only replay of the operator's real gate decision log through the size
// rule on the real disk: decide() with the default 200 MiB limit. Never appends.
import { readFileSync } from "node:fs";
const policy = await import(process.argv[2]);
const lines = readFileSync(process.argv[3], "utf8").split("\n").filter(Boolean);
const roots = policy.protectedRoots();
let n = 0, skipped = 0, over = 0, wouldBlock = [], reads = 0, maxMs = 0;
const kinds = {};
for (const line of lines) {
  const r = JSON.parse(line);
  if (!r.cmd || r.error) { skipped++; continue; }
  let call;
  const m = /^(Grep|Glob|Read) path=(\S*)(?: pattern=(.*))?/.exec(r.cmd);
  if (m) call = { kind: m[1].toLowerCase(), path: m[2] || undefined, pattern: m[3], cwd: r.cwd };
  else call = { kind: "bash", command: r.cmd, cwd: r.cwd };
  kinds[call.kind] = (kinds[call.kind] || 0) + 1;
  const t0 = performance.now();
  const d = policy.decide(call, roots);
  maxMs = Math.max(maxMs, performance.now() - t0);
  n++;
  reads += policy.recognizeReads(call).length;
  over += d.size.reads.length;
  if (d.size.verdict === "block") wouldBlock.push({ ts: r.ts, cmd: r.cmd.slice(0, 200), target: d.size.target, bytes: d.size.bytes });
}
console.log(JSON.stringify({ records: lines.length, replayed: n, skipped_error_or_empty: skipped, kinds, recognized_reads: reads, reads_over_limit: over, size_would_block: wouldBlock.length, max_decide_ms: +maxMs.toFixed(1) }, null, 2));
for (const w of wouldBlock) console.log("WOULD-BLOCK", JSON.stringify(w));
