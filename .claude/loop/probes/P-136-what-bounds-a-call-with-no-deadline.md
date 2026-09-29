---
file: packages/core/rpc_dart/.dart_tool/probe/b107_hidden_timeouts.dart
round: 498
commit: 3391d5ed
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-136 — what bounds a call with no deadline, and is the server told?

## Why it exists

Three claims in one lead, and they need one rig: what bounds each call shape when
nobody set a deadline, whether a `grpc-timeout` reaches the server, and whether
the handler ever learns the caller gave up.

## The harness

A channel pair, a handler that NEVER answers (`await Completer<void>().future`),
and a transport decorator recording the `grpc-timeout` header on every outbound
opening frame. Three shapes; each run reports the header, how long the caller
waited, what it threw, and two counters incremented inside the handler —
`entered` and `cancelled`.

**The probe's own budget is 65 s**, one second over the library's hidden 60 s
fallback. That is what makes the difference readable: `gave up after 60.0s` is the
library's bound, `gave up after 65.0s as TimeoutException` is the probe giving up
on a call nothing bounds.

It takes about four minutes. There is no shortcut — the number under test IS
60 seconds, and a shorter stand-in would exercise the deadline path instead,
which works.

## The numbers (round 498)

```
no deadline                                                 before   after
unary         grpc-timeout=[null]  gave up after 60.0s      cancelled=0   1
clientStream  grpc-timeout=[null]  gave up after 60.0s      cancelled=0   1
serverStream  grpc-timeout=[null]  gave up after 65.0s      cancelled=0   0

with a 500 ms deadline, as the control
unary         grpc-timeout=[498838u]  gave up after 0.5s  RpcDeadlineExceeded  cancelled=1
clientStream  grpc-timeout=[499374u]  gave up after 0.5s  RpcDeadlineExceeded  cancelled=1
serverStream  grpc-timeout=[499517u]  gave up after 0.5s  RpcDeadlineExceeded  cancelled=1
```

## Measures

Wall-clock to give up, the exception type, the `grpc-timeout` header as sent, and
the handler's own view of whether it was cancelled. The last is counted inside the
handler because that is the only place that knows what the application was told.

## Control

The deadline rows, which are the same shapes on the same rig with one thing added.
They show every piece of machinery working: the header is sent, the bound is the
deadline, the type is `RpcDeadlineExceededException`, and the handler is cancelled.
So each no-deadline row is a comparison rather than an absolute.

**The control is also what revealed a mis-aimed witness.** Because the deadline
path already cancels the handler (via the call scope), a test using a short
deadline passes whether or not the timeout path notifies — verified by ablation.
The client-stream half therefore has no fast witness at all, and this bench is its
only evidence.

## What it establishes, and what it does not

Establishes: unary and client-stream are bounded at 60 s by a number nobody
configured, server-stream is not bounded at all, no `grpc-timeout` is sent when
there is no deadline, and before round 498 none of the three told the server.

Does NOT cover the zero-copy unary path through `_executeUnaryCall`, which the
lead names as a fourth shape with no bound.

Does NOT decide whether the 60 s should exist. The rows say what happens; the
choice is in B-107.
