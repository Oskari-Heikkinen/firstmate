# Component maps

A component map names, for one repository, which component skill governs which paths.
It is the only path-to-skill source: the component hook, the brief's component section, the review pack and the drift check all read it through `bin/fm-component-map.sh`, whose header owns the commands and the exit codes.
A component skill states the component's goal and operating principle, the scrappy fixes to refuse and a review checklist, so an agent that touches a path gets the component's rules and a reviewer gets its checks.

## Repository map

The map lives at `docs/component-map.json` in the repository it describes.

```json
{
  "schema": "component-map/v1",
  "roots": ["lattice_*/**", "tools/**"],
  "components": [
    {"id": "run-ledger", "skill": "run-ledger", "paths": ["lattice_ledger/**", "docs/run-ledger.md"], "provisional": false},
    {"id": "xp-contract", "skill": "xp-contract", "paths": ["tools/xp_contract/**"], "provisional": true}
  ]
}
```

- `schema` is exactly `component-map/v1`.
- `components` is a non-empty list; every component has exactly these keys:
  - `id`: unique within the map, matching `[A-Za-z0-9][A-Za-z0-9._-]*`.
  - `skill`: a kebab-case skill name, found at `.agents/skills/<name>/SKILL.md` or `.claude/skills/<name>/SKILL.md`; a name present in both is an error.
  - `paths`: a non-empty list of globs relative to the repository root.
  - `provisional` (optional, default `false`): the component's code has not landed yet, so its globs may match nothing.
- `roots` (optional): globs naming the trees the map claims to cover completely.
- Any other key is an error, so a misspelled key cannot silently do nothing.

Several components may claim the same path; every one of them applies to it.
Two components may also name the same skill.

### Globs

A glob is matched against a whole repository-relative path with `/` separators.
`*` matches any run of characters except `/`, `?` matches one character except `/`, and `[...]` is a character class (`[!...]` negates).
`**` must be a whole path segment: `dir/**` matches every path below `dir`, `a/**/b` matches `a/b` and `a/x/y/b`, and `**` alone matches every path.
A glob may not be empty, start with `/`, end with `/`, or contain an empty, `.` or `..` segment.

### Component roots

The component roots are the files the map's `roots` globs match among the repository's tracked files (`git ls-files`).
Every one of them must match at least one component's glob, so a new file in a covered tree cannot land without an owner.
Files outside the roots may stay unmapped, so a repository can map only its architecture-bearing trees.
A map without `roots` has no coverage requirement.

### Provisional components

`check` requires every glob of a non-provisional component to match at least one tracked file, so a renamed or deleted tree is caught.
A provisional component is exempt from that rule, and `check` prints a note once all its globs match, so the owner can drop the flag.
Matching is otherwise the same: an agent creating the first file of a provisional component gets that component's skill.

## Home-local map

Components whose source is not in any repository (for example kit folders in a home's `data/`) go in `$FM_HOME/config/component-map.json` of the owning home.
It has the same schema with three differences: every glob in `paths` is an absolute path glob, `skill` is the absolute path of a `SKILL.md` (normally in a checkout of the repository that owns the skill), and `roots` is not allowed.
`drift` accepts a home map directly; `check`, `touched` and `review-pack` read only a repository's map.

## Component skill shape

A component skill is a normal skill directory whose `SKILL.md` has YAML frontmatter and a Markdown body.

Frontmatter, matching skill-creator's validator:
- Allowed keys: `name`, `description`, `license`, `allowed-tools`, `metadata` and `compatibility`.
- `name` is kebab-case, at most 64 characters, and equals the skill's directory name.
- `description` is non-empty, at most 1,024 characters, and has no `<` or `>`; it starts with the load condition, then the operating principle and goals.
- `compatibility`, when present, is a string of at most 500 characters.
- The frontmatter must use the YAML subset the checker reads: block mappings and sequences, plain or quoted scalars, and `|` or `>` block scalars; flow collections, anchors and tags are refused.

Body sections, each a level-2 heading with exactly this title:

| Section | Required | Content |
|---|---|---|
| `## Goal and operating principle` | yes, non-empty, at most 1,500 characters | Why the component exists and the principle a change must keep; the text the component hook injects on a first touch |
| `## How it works` | no | The data flow and the owning modules, linking to the contract doc rather than restating it |
| `## Long-term-correct patterns` | no | What a change should look like |
| `## Refuse` | yes, non-empty | Named scrappy fixes, each with the rule it breaks |
| `## Review` | yes, non-empty | Numbered checks a reviewer answers with PASS or a finding; the text the review pack carries |

A required section may appear only once.
Other sections are allowed, so an existing builder-facing skill can be extended in place.
A section ends at the next level-1 or level-2 heading outside a fenced code block.
The goal limit keeps every component one tool call touches inside the hook's 10,000-character output cap.

### Source pins

A skill pins the documents that define its component in `metadata.sources`, a list of entries with exactly a `path` and a lowercase 64-hex `sha256`:

```yaml
metadata:
  sources:
    - path: docs/kind-contract.md
      sha256: 2c68b933...
```

A `path` is absolute, starts with `~/`, or is relative to the root of the repository holding the skill (the skill's own directory when it is in none).
The pins live only in the skill, so the map and the skill cannot disagree about them.
`drift` reports a pin whose source changed or vanished; the owner then reads the source's change, updates the goal, refuse and review sections, and pins the new hash.
Pins are optional, and a skill with none never drifts.
