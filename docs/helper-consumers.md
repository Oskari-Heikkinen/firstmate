# Helper consumers

Some homes run a Firstmate helper, such as `bin/fm-disk-room.sh`, straight from a Firstmate checkout and refuse unless its bytes match a version they reviewed.
A Firstmate update that changes those bytes in place would stop that consumer until it reviews and accepts the new version.
This page is the owner of the rule that prevents that, the declaration format a consumer writes, and what each side does.
`bin/fm-helper-consumers.sh` owns the exact commands, paths, and output in its header.

## The rule

A Firstmate helper that another home runs under a pin is a reviewed helper with declared consumers.
Firstmate deploys a new version of it to the path those consumers run only after every declared consumer accepts that exact version.
A consumer accepts a version through an independent review of those exact bytes; an interface version or self-test the helper advertises is evidence for that review, never acceptance by itself.
Landing does not wait for acceptance: a change to the helper lands on the default branch once its own gates pass, and [the update gate](#the-update-gate) then holds every update that would deploy it until its consumers accept it.
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

## The update gate

The paths that move a Firstmate home's checkout - `/updatefirstmate`, the startup and launch secondmate sync, and remote secondmate sync - go through one fast-forward step, and the gate runs inside it.
A Firstmate clone registered as a project under `projects/` is refreshed by the landed-project sync instead, which this gate does not cover, so a consumer pins a Firstmate home's checkout rather than such a clone.
For each declared helper inside the checkout being moved whose bytes would change:

- if every declaring consumer accepts the new version, the checkout advances;
- if a consumer accepts the current version but not the new one, the checkout stays where it is and its status line says which helper version is waiting on which consumer;
- if a consumer accepts neither, it is already waiting, so holding cannot help: the checkout advances and the update reports it.
- if any declaration is malformed or unreadable, the checkout stays where it is, as described under Declarations.

When the main checkout is held, `/updatefirstmate` holds its whole pass, so every home stays on one Firstmate version, prints a `held-for-helper:` line, and records the hold in the hold log below.
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
It never refuses or delays a landing, and its output never changes whether the head lands.
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
A held pass writes one `held` line for each helper version it waits on, and a rerun that is still held writes another with its own time.
When the gate check itself fails, so no version is known, the pass writes one `held` line with `-` for the helper, version and consumers.
The first later pass of that home that updates or finds itself already current writes one `cleared` line for each version it still had open, noting any `--allow-helper-break` it used.
The log is the record of how long each hold lasted: `bin/fm-helper-consumers.sh holds --windows` reads it back as one line per hold window, with its start, end or `open`, length, held passes, versions and closing note, and `holds --open` lists the holds not yet cleared.

`bin/fm-helper-consumers.sh log` is the log's only writer, and any tool that records a hold, a bypass or a break calls it rather than writing the file:

```
fm-helper-consumers.sh log <outcome> <home> <target-commit> <helper> <sha256> <consumers> [<note>]
```

Each call appends one tab-separated line in a single write:

```
<utc time> <outcome> <home> <target-commit> <helper> <sha256> <consumers> <note>
```

- `held` - a pass of `<home>` stopped at `<target-commit>` because `<consumers>` have not accepted `<helper>` version `<sha256>`.
- `cleared` - a later pass of `<home>` advanced past that held version.
- `bypass` - a held pass on a version that reached the default branch around a landing check that should have refused it; it opens and clears like `held`.
- `break` - an operator-run `--allow-helper-break` moved past `<consumers>`' acceptance of that version; it is a record only and opens or clears nothing.

`<home>` is an absolute path, `<sha256>` may be `absent` for a deleted helper, and `-` stands for an unknown target commit, helper, version or consumer list; the script header owns the exact field rules and exit codes.
This interface is stable: new outcomes and new trailing fields may be added, but no field or outcome is renamed, removed or reordered, and readers ignore what they do not know.

## The unaccepted-version alarm

A version of a declared helper that sits on the origin default branch unaccepted for longer than a limit raises an alarm, so a hold that nobody is reviewing is never silent.
The alarm runs in the main home as the custom watcher check `helper-unaccepted`, installed by `bin/fm-helper-consumers.sh alarm --arm` and removed by `alarm --disarm`.
Each pass raises one level, `helper-unaccepted-<helper>-<sha12>`, per pending version that the branch carries and some declaring consumer has not accepted, once the commit that brought those bytes to the branch is older than the limit.
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
