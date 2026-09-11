---
file: packages/core/rpc_dart/.dart_tool/probe/discarded_log_strings_all_shapes.dart
round: 337 — the validating round
commit: 5caec3baac876bc8b7ab2896d73d3c85542b279c
paths: [packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/**, packages/core/rpc_dart/lib/src/logger/**]
status: valid
---

# P-36 — log strings built for a level that discards them, on all four shapes

Drives unary, serverStream, clientStream and bidi over an in-memory pair and
reports, per round trip, how many `internal`/`trace`/`debug` messages were built
and then thrown away, and how many characters that was.

Needs two counters added to `LogScope` by hand for the run — `probeCalls` and
`probeChars`, incremented in `_NoopLogScope.internal/trace/debug` and in
`LogScope._log`'s `!accepts` branch — and removed before committing; as public
statics they would be an API addition. Round 333's `discarded_log_strings.dart`
is the unary-only ancestor and counts at the noop point only.

## Measures

Discarded log calls and discarded characters per round trip, per call shape,
under **two** logger configurations: none attached (`LogScope.noop`) and a real
`LogController` at `error` level. The second is the one that matters for a
deployment and the one round 333 never took.

## Control

The mechanism is the level guard. Removing it means running the same four shapes
on the tree before the guards went in:

```
                before (unguarded)     after (158 sites guarded)
             calls/rt  chars/rt        calls/rt  chars/rt
unary             6.0       263             1.0        27
serverStream     42.0      2297             5.0       145
clientStream     36.0      1976             4.0       131
bidi             28.0      1632             1.0        33
```

Identical in both configurations, before and after: attaching a logger at
`error` does not stop one character being built. That equality is also what
shows the two instrument points count the same sites.

**The wall clock cannot see this** and the probe prints it anyway, so the
temptation is recorded rather than acted on: `us/rt` moved 289.4 -> 269.7 on
serverStream against a predicted ~2.7 us effect. The spread is an order of
magnitude larger than the signal. Only the counters are valid here.

**It is core-only.** A wrong guard in `rpc_dart_http2` leaves every number
above unchanged — verified by ablating one and re-running. The transports need
their own witness, which is why round 337 wrote one.
