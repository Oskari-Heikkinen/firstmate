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
- [`references/no-mistakes-drive.md`](references/no-mistakes-drive.md) - before starting no-mistakes: what `--intent` may carry, how to drive the run, and when a pipeline block is real.
- [`references/direct-push-landing.md`](references/direct-push-landing.md) - after a direct-push landing push: waiting for the default branch's checks.
