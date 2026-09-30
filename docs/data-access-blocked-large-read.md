# Data-access skill: the "Blocked large read" section

This file is the source of one section of the `data-access` agent skill, which lives in the lattice-research project at `.claude/skills/data-access/SKILL.md`, not in this repository.
The data gate's size-rule refusal (`bin/fm-data-gate.sh`, contract in [`data-gate.md`](data-gate.md)) tells the agent to load that skill and read this section.

Install step, done as a lattice-research change: append everything below the line `<!-- section begins -->` to that `SKILL.md` verbatim, and add `or a read the data gate refused as too large` to the end of the skill's `description` trigger, before its colon.
When this file changes, repeat that step so the two copies match.

<!-- section begins -->

## Blocked large read

The data gate refuses a whole-file read of one file over its size limit (200 MiB unless configured): the Read tool without an offset or limit, `cat`, `less`, `grep`, `rg`, `sed`, `awk`, `jq`, `wc`, `sort`, `cut`, a checksum, `zcat`, `dd` without `count=`, a Python `open()` of a literal path, or any `< file` redirect.
Bounded reads always pass, so the refusal is never a reason to stop: go down this list and stop at the first step that answers the question.

1. **Summary first.**
   Open the `DIGEST.md` next to the file if there is one, or its catalog entry (`lattice-data find --entry E`, `lattice-data find-run X`, `lattice-data path ...`) and the ledger's `runs/<entry>.md`.
   Row counts, columns, verdicts and stop reasons are usually answered there.
2. **Bounded window.**
   Read with an offset and a limit; `head -c N` or `tail -c N`; `head -n N` or `tail -n N`; `sed -n 'A,Bp;Bq'` (the `Bq` makes sed stop at line B); `dd if=FILE bs=1M skip=S count=C`; `xxd -l N` or `od -N N`.
   A streamer piped straight into `head` (`zcat FILE | head -100`) stops early and passes.
   To search inside one stored item, use `lattice-data grep ITEM PATTERN`.
3. **Sample.**
   Sample inside a bounded window, for example `head -c 50M FILE | shuf -n 200`, or every Nth line of a window with `head -n 1000000 FILE | awk 'NR%1000==0'`.
   Say in the report that the numbers come from a sample and how it was drawn.
4. **Niced one-off whole read.**
   When the answer needs every byte (a checksum, an exact count), run it once at idle priority: `nice -n 19 ionice -c3 <command>`, which the gate allows.
   Write the output to your task folder rather than into the conversation, and never re-run it to read the answer again.
   Record in the report the path, the size, the exact command, and why a window or a sample was not enough.
5. **Ask.**
   When none of these fits, stop and ask: a worker appends a `needs-decision` status line, and any other session asks main, naming the file, its size, what is needed from it, and why a window, a sample or a niced read will not do.

Never work around the gate by raising the limit, copying, renaming or splitting the file, or wrapping the read in another interpreter.
Our own verified jobs (batch runners, collectors, the audit) are not agent tool calls; the disk-speed cap governs them, not this rule.
