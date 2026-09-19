---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/does_the_drain_converge.dart
round: 403
commit: bcc4745e
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
status: valid — repaired in round 403; the broken version and why it was broken are kept below
---

# P-88 — does a graceful drain converge, or merely expire?

## Why it exists

`RpcHttp2Server._drain` sends GOAWAY before polling and its doc says that signal
"is what makes a gRPC graceful shutdown CONVERGE rather than merely expire".
`RpcWebSocketServer._drain` has the same polling loop and no such signal.
RPC-25, on two implementations of one duty.

The http2 arm lives in that package's own `.dart_tool/probe/` under the same
name: the websocket package does not depend on rpc_dart_http2, so one file
cannot hold both.

## Measures

With a client calling throughout `stop(drainTimeout: 3s)`: how long `stop()`
takes, and how many calls are served AFTER it began.

## Control

The http2 arm is the control: the transport that HAS the admission stop, under
identical load. And the load sweep is a second one — the same question at two
concurrencies, which is what exposed the bench rather than the code.

## The numbers (round 403, repaired)

Eight parked server-streams held open across the drain, so the count can never
read zero and the poll must spend its whole budget on both; four lanes of unary
calls throughout.

```
transport   stop took   before   SERVED after   refused after
websocket    3006 ms      164        1347             3
http2        3016 ms      118           4           514
```

Both now spend the full 3 s, which is the repair working. 337x more work
admitted after shutdown began, and the direction no longer depends on load.
B-60.

## The numbers that made it BROKEN (round 402)

```
lanes   transport   stop took   served before   served AFTER stop began
6       websocket      112 ms         321              70
6       http2            8 ms         285               6
64      websocket        5 ms         512              37
64      http2           36 ms         756              64
```

## Why this is marked BROKEN

**The ordering reverses with load.** Websocket is 14x slower at 6 lanes and 7x
faster at 64. A difference that flips is not the mechanism under test.

The cause is in the instrument: `drainUntilIdle` samples an INSTANTANEOUS count,
and with 5 ms async handlers there is always a moment with no live responder, so
both drains exit on the first zero sample — before admission matters at all.
Neither converged because of GOAWAY, and neither came near the 3 s budget.

Its first version was worse and is the reason the `lanes` parameter exists: a
single sequential caller read **9 ms, 0 served after**, one call at a time
leaving a gap at every sample.

## What made it valid

A load with NO gap: server-streams held open across the drain, so
`activeResponders` never reads zero. Only then does "stop admitting" have
anything to do, and only then can the two transports differ for the stated
reason. Round 403 added that and the answer came out three orders of magnitude
apart.

> **Keeping the broken numbers beside the repaired ones is the point.** The
> same bench, the same servers, one load-shape change: `112 / 70` against
> `3006 / 1347`. A reader who only saw the second could not tell which arm
> earns the conclusion.
