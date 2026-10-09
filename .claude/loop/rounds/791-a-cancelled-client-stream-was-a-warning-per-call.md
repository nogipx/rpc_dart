---
round: 791
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-285 — new
commit: yes
release: changelog
severity: S3
---

# Round 791 — a cancelled client stream was a warning per call

## Target

KV-R-10 continued (L-12, sweep the class): round 790 covered malformed
requests; the other input a peer controls per call is the CANCEL. A handler
that ignores its token finishes after the call is gone, and
`base_processor.dart` warns on "Attempted to send response on inactive
processor". RPC-25 (the same abstraction four times): the four responders
each decide on their own whether to answer after teardown.

## Hypothesis

On some shape, a call the peer cancels after the handler started writes one
warning-or-above record, so the peer chooses how many.

## Before

P-285, 100 calls each on one connection:

```
  shape   cancel                                                    control
  u       0                                                         0
  s       0                                                         0
  c       100  "Attempted to send response on inactive processor"   0
  b       0                                                         0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/warnings_per_cancel.dart`

## Mechanism

`ClientStreamResponder` sent its handler's result whatever had happened to
the call; after a cancel the pipeline has already closed the processor,
whose `send` warns. Unary checks `_callIsOver` and server-stream breaks on
its own `_isActive` before sending; client-stream had neither. It now has
server-stream's `_isActive`, cleared by `close()`, and drops a late answer
at a guarded internal level.

## After

P-285 `cancel`: 0 on every shape; `control`: 0.

## Canary

`test/logger/a_cancelled_client_stream_writes_no_log_line_test.dart`, the
`_isActive` check ANDed with `false`: the witness failed with `Expected:
empty Actual: [ 'Attempted to send response on inactive processor', x10 ]`;
the guard (a client stream nobody cancelled is answered `0`) stayed green.

## The verdict questions

1. Yes: `cancel` against `control` differ in the cancel frame only; and
   client-stream against the three other shapes under the same cancel.
2. Yes: 100 against 0.
3. Library side: records the responder's own `LogController` emitted.
4. After the fix, the same cell showed 100 before it.
5. Yes, quoted above.
6. One half.
7. FIXED.
8. Nothing set aside by a record. The caller-side "Status OK but no
   response payload" warning was weighed and left: it reports the caller's
   own call, one per call the CALLER made, which is not a count the peer
   chooses.
9. None.
A1. One process; the peer is a hand-built channel, the responder its own
    logger.
A2. Volume: cancelled calls per connection.
L1. n/a — no refusal; the record count is the evidence.

## Gate

`fvm dart format` on the two files (0 changed), then `melos run analyze`
green (L-24's order). `melos run test:unit --no-select` green (15 packages,
rpc_dart +2126 ~1, with this change in the tree); `melos run format:check`
green; `melos run license:check` green. `fvm dart test -p node` on the new
test: 2 of 2.

## Not fixed

Nothing in the class: 4 shapes x 2 arms measured, 1 cell fixed.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`.
Probe `../probes/P-285-log-records-per-cancelled-call.md`.
Round `790-a-malformed-request-was-a-log-line-per-call.md`.
Lesson `../lessons/L-24-analyze-after-the-last-format.md`.
