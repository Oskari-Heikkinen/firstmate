# Helper consumers

Some homes run a Firstmate helper, such as `bin/fm-disk-room.sh`, straight from a Firstmate checkout and refuse unless its bytes match a version they reviewed.
A Firstmate update that changes those bytes in place would stop that consumer until it reviews and accepts the new version.
This page is the owner of the rule that prevents that, the declaration format a consumer writes, and what each side does.
`bin/fm-helper-consumers.sh` owns the exact commands, paths, and output in its header.

## The rule

A Firstmate helper that another home runs under a pin is a reviewed helper with declared consumers.
Firstmate deploys a new version of it to the path those consumers run only after every declared consumer accepts that exact version.
A consumer accepts a version through an independent review of those exact bytes; an interface version or self-test the helper advertises is evidence for that review, never acceptance by itself.
A change to the helper lands on the default branch only after every declared consumer accepts the exact bytes it lands, or the operator breaks a named consumer, as [the landing gate](#the-landing-gate) enforces; [the update gate](#the-update-gate) backs it by holding every update that would deploy a version that landed around it.
Never pin a Firstmate checkout without a declaration: an undeclared pin is invisible to Firstmate, and the next update that touches the helper stops it.

## Declarations

A consumer declares itself in one file, `<consumer-id>.conf`, in `${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/helper-consumers.d/` (`FM_HELPER_CONSUMERS` overrides the directory).
The directory is machine-level because consumers are machine-level services.
Each consumer writes only its own file, and Firstmate only reads them.

The file holds `key=value` lines; blank lines and lines starting with `#` are ignored:

```
schema=fm-helper-consumer/v1
consumer=example-service
owner=example-mate
helper=/path/to/firstmate/bin/fm-disk-room.sh
accept=<sha256>
```

- `schema=` comes first, exactly once, and is `fm-helper-consumer/v1`.
- `consumer=` appears once and equals the file name without `.conf`.
- `owner=` appears once and names the home or team that reviews new versions for this consumer.
- `helper=` appears one or more times, each an absolute path to a helper the consumer runs.
- `accept=` appears zero or more times, each the lowercase SHA-256 of a helper version the consumer accepts right now.

The consumer's own tooling keeps `accept=` current from its own acceptance source, for example the exact pins its installed packages carry, written at install.
Any other key, a repeated single key, a relative `helper=`, or a malformed `accept=` makes the whole file malformed.
A malformed or unreadable file is reported by name and accepts nothing.
Because such a file cannot prove what its consumer accepts, it also holds every update that would change any helper a declaration names, including the absolute `helper=` paths it still lists when it can be read, until it is fixed or the captain's override names its file name without `.conf`.
This hold departs from the original plan, which let a malformed file count only as accepting nothing, so that a single typo cannot let a pinned helper be replaced unreviewed.
An unreadable file whose own `helper=` lines cannot be read holds only the helpers other declarations name.
`bin/fm-helper-consumers.sh list` shows every declaration, each helper's live version, and whether the consumer accepts it, is waiting, or is missing its helper.

## The landing gate

`bin/fm-helper-consumers.sh check-land` keeps an unaccepted helper version off the default branch, so the fleet update never has to hold for one.
It compares the bytes each declared helper has on the default branch and after the head lands there, using the same classifier and outcomes as the update gate below.
A head that leaves every declared helper's bytes as they are is never held, whatever else it changes.
A head that changes them lands only when every declaring consumer accepts the new version; a consumer that accepts the current version but not the new one holds it, and so does any malformed or unreadable declaration.
A head that is not yet on top of the default branch holds when both it and the default branch changed the same helper, because the bytes it would land are not known until it is rebased.

Every landing path runs the gate and refuses on any outcome but a pass, before it pushes or merges anything: `bin/fm-ci-push.sh land` (including `--rebased-from`), `bin/fm-pr-merge.sh` for a Firstmate pull request, and step 4 of the direct-push Definition of done.
A gate that cannot read its declarations or revisions refuses too.
A declared helper the gate cannot locate, because its folder is gone or is not in a git checkout, is a stale declaration: the gate names it as `malformed` at every landing and holds as `unproven` only a head that changes a file with the helper's file name, wherever that file lives, because a moved helper keeps its name.
Every other head lands, so one stale path cannot stop unrelated landings; the consumer's owner fixes the path, or the operator's break names the consumer.
A refused worker does not poll: it parks on `check-land --condition` and resumes when the consumers accept, as the worker guide's direct-push landing reference says.
Each consumer's owner reviews the candidate's bytes and adds `accept=` for them in its own declaration, which is what releases the head.
The operator, and never an agent, may land anyway by breaking a named consumer with `--allow-helper-break <consumer>` on the landing command; that consumer then waits until it accepts the new version.
`bin/fm-merge-local.sh` is not gated, because it merges into a local default branch and never lands on a remote.

## The update gate

The paths that move a Firstmate home's checkout - `/updatefirstmate`, the startup and launch secondmate sync, and remote secondmate sync - go through one fast-forward step, and the gate runs inside it.
A Firstmate clone registered as a project under `projects/` is refreshed by the landed-project sync instead, which this gate does not cover, so a consumer pins a Firstmate home's checkout rather than such a clone.
For each declared helper inside the checkout being moved whose bytes would change:

- if every declaring consumer accepts the new version, the checkout advances;
- if a consumer accepts the current version but not the new one, the checkout stays where it is and its status line says which helper version is waiting on which consumer;
- if a consumer accepts neither, it is already waiting, so holding cannot help: the checkout advances and the update reports it.
- if any declaration is malformed or unreadable, the checkout stays where it is, as described under Declarations.

The landing gate above keeps unaccepted versions off the default branch, so this gate is its backstop: it holds only for a version that landed around the landing gate.
When the main checkout is held, `/updatefirstmate` holds its whole pass, so every home stays on one Firstmate version, and prints a `held-for-helper:` line.
The captain may still say to update anyway for a named consumer or malformed declaration; that consumer then waits until it accepts the new version, and the update records the override.
The override covers only the homes on the machine where the update runs: a remote second mate's home is checked against its own machine's declarations, reports its hold, and catches up by itself once its own consumer accepts.
With no declarations, nothing changes: every update and sync behaves exactly as it did before declarations existed.

## Pending versions

As soon as a change to a declared helper lands - when a Firstmate pull request merges, when a Firstmate direct push lands, and at the latest when `/updatefirstmate` fetches - Firstmate records that version for review if any consumer has not accepted it yet.
The record lives in `${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/helper-versions/<helper name>/<sha256>/` and carries the commit, the consumers' currently accepted versions, the change since them, and a read-only copy of the exact bytes as the review artefact.
A reviewer therefore reviews precisely what will deploy, before it deploys; consumers never run that copy.
Firstmate also files one note per pending version to the main firstmate, which routes it to the declared owner.

## What a consumer does

- Declare every helper it pins, before relying on the pin.
- Keep `accept=` equal to the versions it accepts now, and add a new version only after its own review accepts it.
- Review each pending version from its record, then accept it so the next update can deploy it.
- When a version reaches it unaccepted anyway, wait visibly and resume by itself once it accepts a version, rather than latching a hold that needs a hand to clear.
