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

## The contract self-test gate

A pinned helper that serves an interface version also ships an executable contract for each version it serves, its `--self-test VERSION`.
CI runs every version the changed helper's own copy still serves through that self-test on any head that changes the helper or a file it loads under a pin, hermetically, and fails naming each failing version, so a new byte version cannot land without passing every contract it claims.
The `helper-selftest` job of `.github/workflows/ci.yml` runs it on each `ci/**` push that changes a gated helper, which includes the exact-head run a landing needs, and on every full and weekly run; a push that changes none skips the job without a runner.
A version the helper's `--interface VERSION` answers with exit 1 is reported as not served and is not run: dropping a version is a planned migration under [the rule](#the-rule), never a gate failure.
Passing the gate is evidence for each consumer's review, never acceptance.
`bin/fm-helper-selftest.sh` owns the gated helpers and the files each pins, the protocol a gated helper serves, the hermetic run and the output in its header.

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
`bin/fm-pr-merge.sh` tells a Firstmate pull request by the origin URL of its own Firstmate checkout, passes another project's pull request quietly, and refuses every merge while that origin URL is absent or unreadable, because it cannot then tell.
Its gate fetches from origin while the task's control lock is held, so it is bounded at two minutes, and a gate stopped at that bound refuses the merge.
A gate that cannot read its declarations or revisions refuses too.
A declared helper the gate cannot locate, because its folder is gone or is not in a git checkout, is a stale declaration: the gate names it as `malformed` at every landing and holds as `unproven` only a head that changes a file with the helper's file name, wherever that file lives, because a moved helper keeps its name.
Every other head lands, so one stale path cannot stop unrelated landings; the consumer's owner fixes the path, or the operator's break names the consumer.
A refused worker does not poll: it parks on `check-land --condition` and resumes when the consumers accept, as the worker guide's direct-push landing reference says.
Each consumer's owner reviews the candidate's bytes and adds `accept=` for them in its own declaration, which is what releases the head.
The operator, and never an agent, may land anyway by breaking a named consumer with `--allow-helper-break <consumer>` on the landing command; that consumer then waits until it accepts the new version.
The gate writes each break it takes to [the hold log](#the-hold-log) as a `break` line before the landing goes ahead, naming a malformed declaration by its file name without `.conf`, and refuses the landing when that line cannot be written; a parked `--condition` wait never carries a break.
Once logged, that break line, which the gate marks as its own with a ninth field `taken-by=check-land`, releases the same consumer for the same helper file name and exact bytes (sha256) on every later run of the gate, without the flag, so a break taken on `bin/fm-ci-push.sh land` also passes step 4 of the direct-push Definition of done and a parked `--condition` wait.
A head whose helper bytes differ from the broken version needs its own acceptance or break, and a missing or unreadable hold log counts as no break.
A `break` line written through the `log` subcommand carries no such field and releases nothing, so the operator's `--allow-helper-break` on a landing command is the only supported way to release a hold.
`bin/fm-merge-local.sh` is not gated, because it merges into a local default branch and never lands on a remote.

## The update gate

The paths that move a Firstmate home's checkout - `/updatefirstmate`, the startup and launch secondmate sync, and remote secondmate sync - go through one fast-forward step, and the gate runs inside it.
A Firstmate clone registered as a project under `projects/` is refreshed by the landed-project sync instead, which this gate does not cover, so a consumer pins a Firstmate home's checkout rather than such a clone.
For each declared helper inside the checkout being moved whose bytes would change:

- if every declaring consumer accepts the new version, the checkout advances;
- if a consumer accepts the current version but not the new one, the checkout stays where it is and its status line says which helper version is waiting on which consumer;
- if a consumer accepts neither, it is already waiting, so holding cannot help: the checkout advances and the update reports it.
- if any declaration is malformed or unreadable, the checkout stays where it is, as described under Declarations.

The landing gate above keeps unaccepted versions off the default branch, so this gate is its backstop: it holds only for a version that landed around the landing gate, or on an operator's break.
When the main checkout is held, `/updatefirstmate` holds its whole pass, so every home stays on one Firstmate version, prints a `held-for-helper:` line, and records the hold in the hold log below, as a bypass unless a landing break covers it.
The captain may still say to update anyway for a named consumer or malformed declaration; that consumer then waits until it accepts the new version, and the update records the override.
The override covers only the homes on the machine where the update runs: a remote second mate's home is checked against its own machine's declarations, reports its hold, and catches up by itself once its own consumer accepts.
With no declarations, nothing changes: every update and sync behaves exactly as it did before declarations existed.

## Pending versions

Firstmate records a declared helper version for review, if any consumer has not accepted it yet, at the earliest of these moments:

- before it lands, when a landing candidate changes the helper's bytes: `bin/fm-ci-push.sh land` and a Firstmate direct push's landing steps run the candidate-time notice before the push, and `bin/fm-pr-merge.sh` runs it right before it merges a Firstmate pull request;
- as soon as it lands - when a Firstmate pull request merges, when a Firstmate direct push lands, and at the latest when `/updatefirstmate` fetches.

The record lives in `${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/helper-versions/<helper name>/<sha256>/` and carries the commit, the consumers' currently accepted versions, the change since them, and a read-only copy of the exact bytes as the review artefact.
A reviewer therefore reviews precisely what will deploy, before it deploys; consumers never run that copy.
Firstmate also files one note per pending version to the main firstmate, which routes it to the declared owner.

The candidate-time notice prints one `helper-candidate:` line per unaccepted version, naming the consumers that have not accepted it and warning that its landing holds every home's update until they do.
It never refuses or delays a landing itself, and its output never changes whether the head lands: [the landing gate](#the-landing-gate) runs after it and decides that, so a head the gate holds is still noticed.
A candidate record names its candidate commit and has no landing time yet.
When that version lands, the post-landing run fills in the landing commit and time in the same directory and files no second note, so the review that started at the candidate carries on.
A candidate record whose version has not reached the default branch 14 days after it was recorded is withdrawn: it moves to `retired/` beside the helper's other records, and the owner gets a "candidate withdrawn" note.
If the same bytes come back later, they get a new record and a new note.

### Note evidence

Evidence prepared before the review starts, such as a call-equivalence report, travels in the note's optional evidence field.
A producer writes each evidence file into the record's `evidence/` directory, `<helper name>/<sha256>/evidence/` under the records directory above, before the note is filed, which for a candidate means before the candidate-time notice runs; the directory may be made before the record exists, and a file written after the note is not in it.
The field is the last part of the note, ` Evidence: <path>[; <path>]...`, with the absolute path of each regular file directly in `evidence/` whose name uses only letters, digits, `.`, `_` and `-`, in byte order of their names.
A note with no such file has no field, and any other entry is left out and reported by name.

## The hold log

Every held `/updatefirstmate` pass appends to one machine-wide, append-only log, `holds.log`, beside the pending versions in `${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/helper-versions/`.
A held pass writes one line for each helper version it waits on, and a rerun that is still held writes another with its own time.
The line is `bypass`, because the version reached the default branch around the landing gate, unless the log's `break` lines name every consumer it waits on for that version (matched by helper file name and version), which makes it `held`; a log that cannot be read counts as naming none.
When the gate check itself fails, so no version is known, the pass writes one `held` line with `-` for the helper, version and consumers.
The first later pass of that home that updates or finds itself already current writes one `cleared` line for each version it still had open, noting any `--allow-helper-break` it used.
The log is the record of how long each hold lasted: `bin/fm-helper-consumers.sh holds --windows` reads it back as one line per hold window, with its start, end or `open`, length, held passes, versions and closing note, and `holds --open` lists the holds not yet cleared.

`bin/fm-helper-consumers.sh log` is the log's only writer, and any tool that records a hold, a bypass or a break calls it rather than writing the file:

```
fm-helper-consumers.sh log <outcome> <home> <target-commit> <helper> <sha256> <consumers> [<note>]
```

Each call appends one tab-separated line in a single write:

```
<utc time> <outcome> <home> <target-commit> <helper> <sha256> <consumers> <note> [<taken-by>]
```

- `held` - a pass of `<home>` stopped at `<target-commit>` because `<consumers>` have not accepted `<helper>` version `<sha256>`.
- `cleared` - a later pass of `<home>` advanced past that held version.
- `bypass` - a held pass on a version that reached the default branch around the landing gate; it opens and clears like `held`, and also marks the version so [the alarm](#the-unaccepted-version-alarm) raises it at once.
- `break` - an operator-run `--allow-helper-break` let a landing move past `<consumers>`' acceptance of that version, written by the landing gate with the head as `<target-commit>`; it opens or clears no hold.
  The landing gate marks its own break lines with the ninth field `taken-by=check-land` and reads only those as releasing those consumers for that version, as [The landing gate](#the-landing-gate) says; the `log` subcommand takes no ninth field, so a `break` line it writes is a record only.

`<home>` is an absolute path, `<sha256>` may be `absent` for a deleted helper, and `-` stands for an unknown target commit, helper, version or consumer list; the script header owns the exact field rules and exit codes.
This interface is stable: new outcomes and new trailing fields may be added, but no field or outcome is renamed, removed or reordered, and readers ignore what they do not know.

## The unaccepted-version alarm

A version of a declared helper that sits on the origin default branch unaccepted for longer than a limit raises an alarm, so a hold that nobody is reviewing is never silent.
The alarm runs in the main home as the custom watcher check `helper-unaccepted`, installed by `bin/fm-helper-consumers.sh alarm --arm` and removed by `alarm --disarm`.
Each pass raises one level, `helper-unaccepted-<helper>-<sha12>`, per pending version that the branch carries and some declaring consumer has not accepted, once the commit that brought those bytes to the branch is older than the limit, or at once when a `bypass` line in the hold log marked that version.
The level clears when every declaring consumer accepts the version, or when the branch moves on to other bytes for that helper.
It reaches the main home and the local home of the version's declared owner, as a level in each home's alert store (see [Alert store](alert-store.md)); an owner this machine cannot reach is named in main's level instead.

The limit is the operator's override in `config/helper-unaccepted-max`, read on every pass: one whole number of seconds, or of minutes or hours with an `m` or `h` suffix.
Without the file the limit is 2 hours.
An empty, unreadable or malformed limit file, declaration or pending record, or an unreadable branch, raises its own level naming the file, and an unreadable limit file still counts the 2-hour default for the versions.
With no declarations the alarm prints and writes nothing.
Each pass costs one `stat` per pending record and re-reads only records that changed since the last pass.

## Consumer call sets

A consumer may publish the calls it makes to a helper as data, so its reviewer can see how a new version answers exactly those calls.
The file is `<consumer-id>.calls`, in the same directory as the consumer's declaration, and Firstmate only reads it.
`bin/fm-helper-equiv.sh` runs a call set against two versions of a helper and writes the call-equivalence report; its header owns the commands, output and exit codes.

```
schema=fm-helper-calls/v1
consumer=example-service
helper=bin/fm-disk-room.sh
fixture=example-service.fixture
env=FM_DISK_ROOM_MARGIN=20G
env=FM_DISK_ROOM_STATE=@SANDBOX@/state
state=absent FM_DISK_ROOM_POLICY=@FIXTURE@/no-policy
state=strict FM_DISK_ROOM_POLICY=@FIXTURE@/policy-strict
call=check --expect-write 10G
call=FM_DISK_ROOM_HOST= status --json
```

- `schema=` comes first, exactly once, and is `fm-helper-calls/v1`.
- `consumer=` appears once, before any `helper=`, and equals the file name without `.calls`.
- `helper=` starts the section for one helper, as its path inside the Firstmate repository, because the report reads each version from Git history.
- `fixture=` appears at most once per section and names a directory relative to the call set; every run gets a fresh copy of it.
- `env=NAME=VALUE` lines set the environment of every call in the section.
- `state=NAME [NAME=VALUE...]` lines, up to 8, name each state the helper supports, such as each storage policy state, with the environment that sets it up; every call runs in every state, and a section without one has a single state named `default`.
- `call=[NAME=VALUE...] ARG...` lines, 1 to 200, are the calls in the order the consumer makes them; leading `NAME=VALUE` words set that call's environment, and a leading `--` ends them.
- `timeout=SECONDS` appears at most once per section, from 1 to 600, and bounds each call; the default is 60.
- Words are separated by spaces; inside a word `\s` is a space, `\t` a tab and `\\` a backslash, and `\e` alone is an empty argument.
- `@SANDBOX@` (the run's scratch directory), `@FIXTURE@` (the run's copy of the fixture) and `@PID@` (a process alive for the whole run, for `--pid` arguments) are replaced in every value and argument.
- Blank lines and lines starting with `#` are ignored; any other key, a repeated single key, or a malformed line makes the file malformed, and the report refuses, naming the file and line.

Nothing else is inherited: each call starts from an empty environment with only a fixed `PATH`, a `HOME`, `TMPDIR` and XDG directories inside the sandbox, and the C locale and UTC.
So a call set points every path the helper would read or write at `@SANDBOX@` or `@FIXTURE@`, and the report never touches a real home or live state.

The report runs each version's exact bytes, taken from Git and checked by sha256, in a fresh sandbox per state, with no network where the machine allows it, at nice 19 and idle I/O.
Each state runs the old version twice and the new version once, so a result that changes between two runs of the same bytes is caught.
It has one table row per call, state and aspect (rc, stdout, stderr, or the state left in the sandbox) that differs or is unknown, so identical versions give no rows.
A difference is a finding for the reviewer, never an automatic refusal or acceptance: the report holds or advances nothing, and acceptance stays the consumer's own review.
An unknown - a call that timed out or could not start, an unreadable state, a call past the run's deadline, or an old result that changed between its two runs - is never counted as equal.

## What a consumer does

- Declare every helper it pins, before relying on the pin.
- Publish the calls it makes as a call set, so each pending version's review can include how that version answers them.
- Keep `accept=` equal to the versions it accepts now, and add a new version only after its own review accepts it.
- Review each pending version from its record, then accept it so the next update can deploy it.
- When a version reaches it unaccepted anyway, wait visibly and resume by itself once it accepts a version, rather than latching a hold that needs a hand to clear.
