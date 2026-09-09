# dart: measurements and forensics

> [dart](PACK.md) · appended to the universal
> [methods/measurement.md](../../methods/measurement.md) by `loop.py next`

Dart runtime idioms for the `methods/measurement.md` checklist.

D1. An unhandled error with an empty stack did not come from a throw but from
    `completeError`/`addError` with no stack — look for the completion site.
D2. A guarded zone (`runZonedGuarded`) catches only its own side's errors —
    check whose code threw.

Below is what paid for each item.

## Forensics that narrowed the search fast

- **An unhandled error with an EMPTY stack did not come from a throw but from an
  explicit "complete with an error" with one argument** (in Dart:
  `completeError`/`addError` with no stack). That alone narrowed the search to a
  specific completion site.
- **A crash whose output stops before your own `catch` printed anything did not
  pass through the future you were awaiting.** Look for a detached delivery
  rather than re-reading the expected path.
- **If a guarded zone does not catch what you expect, check which SIDE the
  throwing code belongs to.** A guarded zone around the client (in Dart,
  `runZonedGuarded`) could not catch an exception leak belonging to the server
  side — one measurement moved the entire search.
