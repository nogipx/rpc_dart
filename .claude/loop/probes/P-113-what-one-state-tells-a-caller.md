---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/what_one_state_tells_a_caller.dart
round: 464
commit: 3630c877
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-113 — what one state tells a caller

## Why it exists

B-76 step 2: the reconnect machines answer id reuse — and the disconnected
state — differently. Round 449 benched http2 and only READ the other two, and the
owner attached a question to the rest: *"decide what one state should tell a
caller"*, with the `## Ask` to be answered before any code.

The bench is built to answer that question rather than to confirm the
divergence, and the difference is the arms.

## The harness — TWO arms per machine, which is the point

Every previous record collapses the disconnected state into one word. This
separates it:

```
during a reconnect that is IN FLIGHT   -- the remedy is already running
after a reconnect that FAILED          -- the remedy is the caller's
```

Injectable factory with two knobs — a `stall` and a `failNext` — so both arms are
reached from one transport, in one process, with everything else held. One send
per arm, reported as its TYPE and its status code, because the two machines were
known to differ on the type before this round and the code alone would hide it.

A websocket server that accepts and says nothing; an HTTP/2 server that completes
the handshake and answers nothing. Same shape as round 449's http2-only bench,
which this supersedes by adding the second arm and the second machine.

## The numbers (round 464)

```
                          websocket        http2            health
during the factory await     9              14              degraded
after a FAILED reconnect     9               9              unhealthy
```

One cell disagreed — and the table's real finding is the other axis: **both
machines gave ONE answer to TWO states**, and `health()` already told them apart
(`degraded` vs `unhealthy`) while the status did not.

After:

```
during the factory await   RpcNoConnectionException code=14   both
after a FAILED reconnect   RpcNoConnectionException code=9    both
```

## Measures

The exception TYPE and its `statusCode`, from one `createStream` +
`sendMetadata`. The type matters on its own: http2 read 14 during the await by
ACCIDENT — it discards the connection before the await, so the send path threw
before any guard ran — and a caller branching on the type saw
`RpcNoConnectionException` on one machine and a bare `RpcStatusException` on the
other for the same state.

`health().level` is reported beside each row, which is what showed the two states
were already distinguishable somewhere.

## Control

- **A send with no reconnect anywhere near**, per machine, which returns
  ACCEPTED: so a refusal in the arms is the window and not the setup.
- **A send after the reconnect COMPLETES**, which returns ACCEPTED: so the
  refusal ends, and a transport that simply refused forever would be caught.
- **The two arms are each other's control** for the fix: one type, two codes,
  varying only the state.

## What it establishes, and what it does not

Establishes: the machines disagreed on exactly one cell; both answered one status
for two states; and after the fix the type and the code agree across both.

Does NOT establish whether 14 is the RIGHT answer for the in-flight state. That
is a claim about what a caller does with it, and it is a different bench —
P-114.

## Reading

rpc_dart_websocket + rpc_dart_http2 + core — **two arms per machine, which is
the design**: a send during a reconnect that is IN FLIGHT, and one after a
reconnect that FAILED. Every earlier record collapses those into
"disconnected"; separated, they turn out to want opposite advice, and
`health()` already told them apart (`degraded` / `unhealthy`) while the status
did not. One injectable factory with a `stall` and a `failNext`, so both arms
come off one transport in one process. Reports the exception TYPE as well as
the code, because http2 read the right code by ACCIDENT — from a discarded
connection rather than from its guard. Controls: a send with no reconnect
(accepted), and one after it completes (accepted)
