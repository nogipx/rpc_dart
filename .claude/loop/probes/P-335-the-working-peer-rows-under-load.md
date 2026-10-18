---
file: packages/test/rpc_dart_conformance/.dart_tool/probe/r880_normal_row_under_load.dart
round: 880
commit: ecaab2ae
paths: [packages/test/rpc_dart_conformance/test/i1_every_call_ends_test.dart]
status: stale (526c8d52)
promoted: no — load cannot be a test fixture; the row it times was changed instead
---

# P-335 — the working peer rows under load

`fvm dart run <file> ...` from `packages/test/rpc_dart_conformance`. Machine
load is the variable, made on purpose: it starts N separate processes that
spin. In-process isolates do not work for this. 24 spinning isolates starved
the main isolate, and the run printed nothing for 5 minutes.

- `<burners> <reps> [deadlineMs] [many]` runs the I-1 working-peer row's
  body for every member, `reps` times. It prints the calls that did not end
  OK and the median and max elapsed time. `many` runs the 40-call row
  instead, which uses 4 x the deadline.
- `test <burners> <dart test args>` runs `dart test` in the package with the
  load running.

## Measures

How many calls to a working peer fail, and with which status, when the
machine is loaded.

## Control

`0` burners: no call fails. Max 53 ms for one unary call, and 129 ms in the
40-call row.
