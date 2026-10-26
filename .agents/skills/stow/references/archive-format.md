# Cold-tier archive format

`data/memory-archive.md` is append-only: each pass or cleanup that archives anything appends one batch, and nothing already in the file is edited.
The entry below is fictional and illustrates the format, not a live task or operating instruction.

````markdown
## Archived 2026-08-08 - stow
These are original whole entries, not current operating instructions.

## data/learnings.md:14
Source tier: perishable; last reinforced: 2026-06-30.
Reason: unreinforced 39d.
Moved to: archived only
```text
- The example staging export needs a manual checksum until example-export-checksum lands. <!--p:2026-06-30-->
```
````

- The batch heading is `## Archived <YYYY-MM-DD> - <pass or cleanup name>`.
  A cleanup applied under a go from main appends `(<draft id>, applied on main's go <ISO-Z>, corr=<id>)` and adds one provenance line under the fixed sentence.
- Each entry heading names the source file and the entry's original line number.
- `Source tier:` is the entry's tier (`pinned default`, `aging default`, or a marked tier), and `last reinforced:` is its marker date or `unknown`.
- `Reason:` is one of the reasons the skill lists, or for a cleanup the row id and what happened to the entry (removed, superseded by, folded into, cut, moved).
- `Moved to:` is `skill <name> (tracked)`, `skill <name> (local)`, `file <path>`, or `archived only`; it is the pointer from the old words to their new owner.
- The fenced block holds the exact original line, marker included, never a paraphrase, so recovery is a copy back.

Batches written in the earlier one-line format (`- (from learnings.md, tier: ..., reinforced: ...) <entry> [archived: <reason>]`) stay as they are; never rewrite an archived batch.
