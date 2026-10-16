---
round: 880
verdict: FIXED
packages: [rpc_dart_conformance]
lens: RPC-15
bench: P-335 — new
commit: yes
release: none
severity: S0 — "the loop's tooling, gates, tests"
---

# Round 880 — the working peer rows are held to an ending not a speed

## Target

B-297, the highest-ranked open lead the round may take; the one ranked
above it waits on the owner. In rounds 877-879 the full gate went red in five of
nine runs, so every round pays for it. The lead names seven tests with
fixed wall-clock budgets. This round takes the one in the matrix,
`i1_every_call_ends_test`, whose working-peer row failed with `status 4,
300 ms deadline`. That row runs over every transport.

Class count in the matrix (L-12). I grepped every `deadline:` under
`packages/test/rpc_dart_conformance/test` and checked whether a working
peer has to answer OK inside it. Two rows do, both in i1: the shape x
behaviour row for `peer normal` (300 ms), and `40 calls, every shape,
working peer` (1200 ms). `i5 ... close after peer` also uses 300 ms but
never checks the outcome. The rest are hostile-peer endings, which are the
subject of their rows, or deadlines of 1 s or more on hanging handlers.

Set aside: while reading the new rpc_dart_socket package I formed two
hypotheses and did not measure them. They are filed as leads (Links), and
this round rules neither out.

## Hypothesis

The row holds a correct call to a 300 ms wall-clock deadline. Under the
gate's load (load average 25 on 8 cores), a correct call takes longer than
that and fails with DEADLINE_EXCEEDED. If the failures stay when the load
is removed, or do not appear when it is added, the hypothesis is wrong.

## Before

P-335, the row's body run 10 times per member. Load comes from N separate
spinning processes on an 8-core machine.

```
                      single unary call (300 ms)        40-call row (1200 ms each)
burners  member       not OK   median   max             not OK     median   max
0        all six      0/60     <=11 ms  53 ms           0/720      <=67 ms  129 ms
24       http         2/10     167 ms   578 ms          60/120     1250 ms  1767 ms
24       http2        1/10     253 ms   616 ms          0/120      599 ms   746 ms
24       channel      0/10     80 ms    784 ms          0/120      567 ms   1304 ms
```

Every failure is status 4. The test file run under the load,
`... test 48 test/i1_every_call_ends_test.dart --name "normal|working
peer"`, failed 8 cells: channel, http and http2 in several shapes, and the
http 40-call row. All failed `status 4: RpcDeadlineExceededException`.

Probe: `packages/test/rpc_dart_conformance/.dart_tool/probe/r880_normal_row_under_load.dart`

## Mechanism

A deadline that tests a hostile peer's ending was also applied to the
working peer. For a working peer the deadline only measures how fast the
machine is.

## After

`_workingDeadline = 10 s`, bounded by `+ 1 s`, for the two working-peer
rows. Hostile rows keep 300 ms. With 48 burners: `+30 ~5: All tests
passed!`, twice. The whole file with no load: `+124 ~30: All tests
passed!`. P-335 at 48 burners puts the 40-call row's worst call at
12179 ms (http), so 10 s holds up to about twice the gate's observed load
and not further. 5 s was tried first and failed that row once at 48
burners.

## Canary

`_workingDeadline` set back to 300 ms in place. With 48 burners, 8 cells
failed, for example `I-1 every call ends, peer normal: http | unary peer
normal`: `Expected: true Actual: <false> status 4:
RpcDeadlineExceededException: ... exceeded (timeout: 0:00:00.299810)`.
Restored, the same run passes. The witness is the cell under load. The
guard is `_workingDeadline`.

## Gate

All green: `melos run analyze` (after the format), `test:unit:quiet`
(conformance `+620 ~152`, rpc_dart `+2265 ~1`, every package passed, at
load 8.7), `format:check`, `license:check`.

## Siblings

—

## Not fixed

- Six of the seven tests B-297 names: http `graceful_drain_on_stop_test`
  (twice), http2 `tiny_messages_are_weighed_test`, conformance `i3 an
  oversized message that never finishes: socket` (2 s), isolate
  `isolate_verification_test`, and rpc_dart's known
  `audit_frame_reassembly_linear_test`. Each has its own budget and
  mechanism. P-335's `test <burners> ...` mode can drive any of them.
  B-297 stays open.
- On the client side of peer mode, `RpcWebSocketCallerTransport` does not
  forward `IRpcConnectionBufferTotal`; `RpcSocketCallerTransport` does. A
  responder half over the websocket caller is then held to the total once
  per layer: twice, still bounded. Not measured.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md`. Bench
`../probes/P-335-the-working-peer-rows-under-load.md` (new). Lead
`../backlog/B-297-the-tiny-messages-witness-times-out-under-the-gate.md`
updated, still open. New leads `../backlog/B-298-the-socket-channel-writes-with-no-bound-on-what-the-peer-has-not-read.md`
and `../backlog/B-299-a-stale-socket-file-is-any-connect-failure.md`.
Lesson L-19 applied: load is the variable and was varied on purpose.
Q9: none. Burners have to be separate processes, not isolates, and that
is written in P-335. It cost one rebuild.
