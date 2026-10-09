---
round: 793
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: P-286 — new
commit: yes
release: changelog
severity: S3
---

# Round 793 — an advisory error was an incident per frame

## Target

KV-R-10 on the transport side, after rounds 790-792 swept the responder
pipeline: the same peer-repeated inputs, now over a real websocket socket,
counted at the server. `loop.py find "peer-triggered warning fires once per
call per stream log amplification"` named B-124 and rounds 603-605, which
guarded the pipeline's refusal sites, none the transport-error handler.

## Hypothesis

Some cheap input a peer can repeat over a working connection makes the
server write one warning-or-above record each time.

## Before

P-286, 100 repetitions each:

```
  input                  records   kind
  text frame             100       error  RpcWebSocketNonBinaryFrame (advisory)
  too many headers       100       error  _OneStreamViolation (advisory)
  binary garbage         1         error  connection closed 4413
  six other inputs       0
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/log_records_per_hostile_input.dart`

## Mechanism

Both pipelines' `incomingMessages.onError` logged every transport error at
ERROR first and only then asked whether it was `IRpcAdvisoryChannelError`
-- the marker that says "a discarded frame on a connection that still
works", which the responder already used to skip answering every call.
So the classification existed and decided the response, but not the log
level. `caller_pipeline.dart`'s copy is the same handler without the
answering half, which lets a hostile server do this to a client.

## After

Advisory errors: one warning per endpoint ("Transport reported a discarded
frame (logged once per connection)"), on both pipelines. Others: ERROR as
before. P-286: 1, 1, 1, 0 x 6.

## Canary

`test/logger/an_advisory_error_is_reported_once_test.dart`. Responder half
off (`IRpcAdvisoryChannelError && false`): its witness failed, `Expected:
empty Actual: ['Transport incoming error' x10]`; the caller witness and
the guard green. Caller half off: its witness failed the same way, the
responder witness and the guard green. GUARD: a channel `addError` with no
advisory marker is still logged `Transport incoming error` at ERROR.

## The verdict questions

1. Yes: advisory against non-advisory inputs on the same rig; and each
   witness against the control row.
2. Yes: 100 against 1.
3. Library side: records the server's own `LogController` emitted.
4. n/a — counts after are 1, from the same bench that read 100.
5. Yes, quoted.
6. Yes: two halves, two canaries, each failing only its own witness.
7. FIXED.
8. `caller_incoming_drain_test.dart` pinned the old level ("a caller
   surfaces transport-level errors": an ERROR containing "Transport
   incoming error"). Its reason line says what it guards -- that the error
   is not silently discarded -- and that still holds: the assertion now
   reads a record at warning or above containing "discarded frame".
9. None.
A1. Separate processes are not needed; client and server in one process,
    the server with its own logger and default policy.
A2. Volume: frames per connection.
L1. n/a — the evidence is a record count.

## Gate

`fvm dart format`, then `melos run analyze` green; `melos run test:unit
--no-select` red once on `caller_incoming_drain_test.dart` (above), then
green after it (15 packages, rpc_dart +2130 ~1); `fvm dart analyze
--fatal-infos --fatal-warnings packages/core/rpc_dart` clean after the last
edit; `melos run format:check` green; `melos run license:check` green.
`fvm dart test -p node` on both tests: 7 of 7.

## Not fixed

Nothing in the class on the websocket path. The two remaining per-frame
sources measured (none) are listed in P-286.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`.
Probe `../probes/P-286-log-records-per-hostile-websocket-input.md`.
Round `792-the-no-op-frame-warning-was-reachable-after-all.md`.
Round `604-the-peer-chose-how-many-lines.md`.
Lesson `../lessons/L-24-analyze-after-the-last-format.md`.
