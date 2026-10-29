---
name: worker-guide
description: >-
  Worker-only references a ship or scout brief names by absolute path; read the file your brief names at the trigger it states.
user-invocable: false
metadata:
  internal: true
---

# Worker guide

A ship or scout brief names one of these files by absolute path at the point a worker needs it, because a worker in another project has no Firstmate skill index.
The brief stays the worker's safety contract and wins on any conflict.

- [`references/waits-and-parking.md`](references/waits-and-parking.md) - before a wait longer than a few minutes: wait tags that keep monitoring quiet, and parking.
- [`references/no-mistakes-drive.md`](references/no-mistakes-drive.md) - before starting no-mistakes: setup, what `--intent` may carry, how to drive the run, and when a pipeline block is real.
- [`references/direct-push-landing.md`](references/direct-push-landing.md) - when a direct-push landing push is refused or succeeds: the push-race bound and waiting for the default branch's checks.
- [`references/firstmate-verification.md`](references/firstmate-verification.md) - before the first push of a direct-push task on Firstmate's own repository: the lean pre-push review, the commit-message lines CI requires, waiting on the CI branch, and parity tests; the brief's Definition of done owns the local checks, what to push to CI and when, and handling a red run.
