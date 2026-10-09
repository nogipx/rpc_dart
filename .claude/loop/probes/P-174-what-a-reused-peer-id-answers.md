---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b199_pipeline_stale_teardown.dart
round: 541
commit: aeebbbfb
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
status: valid
---

# P-174 — what does a caller on a reused peer stream id receive?

## Why it exists

`P-161` asked the same question of the transport alone and said in its own record that it
did not drive a pipeline: the stale calls were made directly, which measures the
transport's contract rather than whether a deployment reaches it. This drives the real
responder.

The measure is the ANSWER a caller gets, not a frame count. Two callers, two different
connections, one stream number: the only way to say the wrong one was served is to read
what each was told.

## The harness

A real `HttpServer` with `RpcWebSocketServer` in peer mode, and a client
`RpcPeerEndpoint` over `RpcWebSocketCallerTransport.connect`. The client registers one
unary method whose handler parks on a per-request gate, so one answer can be held across
a reconnect while another call runs.

**The id collision is not staged, it is the server's ordinary behaviour.** A dropped
connection gets a FRESH server endpoint, which numbers its first stream from the bottom —
so the second call lands on the first one's id with nothing contrived.

The client pipeline's own log records are captured at `internal` level. Which branch it
took for the reused id is not inferable from the caller's result: ignored as a repeat
opening frame, served, or torn down by the old call's tail cleanup all look the same from
outside.

## The numbers (round 541)

```
  arm                                   "two" got       handler started / cancelled
  reconnect, id REUSED, old answer late  answered one   [one]         / []
  reconnect, first call already done     answered two   [one, two]    / []
  CONTROL no reconnect (ids 2 and 4)     answered two   [one, two]    / []
```

Row 1 is the finding: the caller asking `two` was handed the answer to `one` — a different
call, from a different caller, on a connection that no longer exists — and its OWN request
was never dispatched.

After the fix, row 1 reads `answered two` with `started [one, two]` and `cancelled [one]`,
and the pipeline records the two decisions that make it so: `Operation cancelled, stopping
request handling [id: 2]` and `Skipping a stale cleanup for stream 2: the id now names
another call`.

## Measures

What the second caller receives; which handlers ran; which of them observed cancellation;
the ids the peer opened on (read off the client's own inbound stream, since the server
transport does not publish its cursor); and stray root-zone errors, which must be 0.

## Control

**Row 3, no reconnect at all**, with the two answers released out of order on one
connection. Without it, "the second caller got the first one's answer" is equally
consistent with out-of-order release being broken by itself. Here the ids are 2 and 4 and
each caller gets its own.

**Row 2 is the second control and the sharper one**: the same reconnect, the same reuse of
id 2, differing only in whether a call was still parked when the number came round again.

## What it establishes, and what it does not

Establishes: through the real pipeline, a peer id reused after a reconnect is answered by
the previous call, and three independent mechanisms contribute — the old stream state
surviving the drop, the parked responder writing on the number, and the old call's tail
cleanup acting on whatever the number names.

Does NOT establish anything about the streaming shapes. Only unary was driven; the three
others reach `_cleanupStream` through `responder.done`, which is the same shape and is not
measured here.

Does NOT price the window. Whether the pipeline's reclamation wins the race against the new
socket's first frame is left to the reconnect's own awaits, and this rig does not vary the
handshake latency.

## Rig errors it cost

**The first caller's failure was reported as unhandled.** Its socket goes away under it by
construction, and a `Future` completing with an error whose handler is attached LATER is
reported to the zone in the meantime. It read as a library defect — `RpcCancelledException:
Endpoint closed` from the root zone — and is a property of the rig. The handler is now
attached where the call is made.

**`endpoint.transport.incomingMessages` on the server side recorded nothing** in any arm,
including ones where frames demonstrably flowed. Dropped in favour of the client's own
inbound stream and the pipeline's records; an observable that reads empty in the control is
not an observable.

## Reading

rpc_dart_websocket + rpc_dart — **measures the ANSWER a caller gets, not a
frame count.** Two callers on two connections share one stream number, and the
only way to say the wrong one was served is to read what each was told: row 1
handed the caller asking `two` the answer to `one`. The collision is the
server's ordinary behaviour, not staged — a dropped connection gets a FRESH
endpoint, which numbers from the bottom. Captures the client pipeline's own
records at `internal`, because ignored-as-a-repeat, served, and
torn-down-by-the-old-call all look identical from outside. Supersedes
`P-161`'s open question: that bench said in its own record that it never drove
a pipeline.
