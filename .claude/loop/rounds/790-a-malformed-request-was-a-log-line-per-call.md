---
round: 790
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: P-284 — new
commit: yes
release: changelog
---

# Round 790 — a malformed request was a log line per call

## Target

The network-audit skill's KV-R-10 (peer-triggered log amplification), on
the code round 787 had just touched: `answerIncompleteRequest` warned
unconditionally, and round 787 kept and extended that warning. CLAUDE.md:
a warning a peer can trigger repeatedly fires once. Rounds 603-605 (B-124)
removed per-call warnings from the responder PIPELINE; `loop.py find
"peer-triggered warning fires once per call per stream log amplification"`
names nothing in the stream RESPONDERS, which is where these sit. RPC-22:
the refusal path is reachable by anyone.

## Hypothesis

A peer repeating one malformed call writes one warning-or-above record per
call on some shape; the class is counted on all four shapes and four inputs
before fixing.

## Before

P-284, 200 calls each on one connection:

```
  shape  empty   truncated   noData   complete
  u      200     200         200      0
  s      0       200 (error) 0        0
  c      0       0           0        0
  b      0       0           0        0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/warnings_per_peer_call.dart`

Also measured: a bare half-close on a channel transport arrives as an empty
DATA frame with the end flag, so `noData` reaches `answerIncompleteRequest`
too; its status message read "mid-message: the last gRPC frame is
incomplete" before round 787 and "after an empty payload frame" after it,
both wrong for a call that sent no payload.

## Mechanism

Two sites, one shape: a malformed request is the peer's error, answered
INVALID_ARGUMENT, and client-stream and bidi answer it without a record.
`UnaryResponder.answerIncompleteRequest` logged a warning per call;
`ServerStreamResponder`'s request-stream `onError` logged at ERROR per call,
although its own handler path in the same class already logs faults only
(`RpcStatus.isFaultError`, round 603's idiom).

## After

P-284: 0 in every cell. Unary's line is now guarded `internal`;
server-stream's `onError` logs only `isFaultError`. The non-mid-frame
status message reads "Request stream closed without a request message".

## Canary

`test/logger/a_malformed_request_writes_no_log_line_test.dart`.
Unary half off (the warning restored): the three unary witnesses failed,
each `Expected: empty Actual: [20 records]`, the server-stream witness and
both guards green. Server-stream half off (the `isFaultError` gate made
always-true): its witness failed with 20 `Error in request stream [id: N]`
records, the unary witnesses and guards green. GUARD: a transfer-mode
mismatch on a server stream (status 13, a fault) still writes `Error in
request stream`.

## The verdict questions

1. Yes: per shape, the malformed input against `complete`, same peer, calls
   and logger; and two shapes against client-stream and bidi on the same
   inputs.
2. Yes: 200 against 0.
3. Library side: records the responder's own `LogController` emitted.
4. The zeros after the fix: the same bench showed 200 before, on the same
   cells.
5. Yes: `Expected: empty Actual: [...]` with the records quoted, per half.
6. Yes: two halves, two canaries, each failing only its own witnesses.
7. FIXED.
8. Rounds 603-605 were a pointer: the pipeline's guards were not re-read as
   evidence; every cell was measured today.
9. L-24: analyze after the last format; price, this commit rebuilt once.
   (The logging rule itself exists in CLAUDE.md; round 787 broke it in the
   file it was fixing, which L-22's shape already names.)
A1. One process; the peer is a hand-built channel, the responder its own
    logger and default policy.
A2. Volume: calls per connection.
L1. The witnesses count records, not a refusal; the status is checked
    alongside (INVALID_ARGUMENT on every call).

## Gate

`melos run analyze` green, then `dart format` split a one-line `if` in the
new test and the first commit carried a `curly_braces_in_flow_control_structures`
info that the analyzer had not seen; found by round 791's analyze, fixed,
and this commit rebuilt (L-24). After it: `fvm dart analyze --fatal-infos
--fatal-warnings packages/core/rpc_dart` clean; `melos run test:unit
--no-select` green (15 packages, rpc_dart +2126 ~1); `melos run
format:check` green; `melos run license:check` green. `fvm dart test -p
node` on the new test and round 787's: 9 of 9.

## Not fixed

Nothing in the class: 16 cells and the unregistered method measured, 4 in
2 shapes fixed. The status text change is a changelog line.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`.
Probe `../probes/P-284-log-records-per-malformed-call.md`.
Round `787-an-empty-unary-payload-was-never-answered.md`.
Round `604-the-peer-chose-how-many-lines.md`.
Lesson `../lessons/L-22-a-new-wait-owes-its-awaiters-a-bound.md`.
