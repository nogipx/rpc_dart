---
round: — (pre-201, off-journal; imported in the curate pass after 234)
commit: d9b96a67
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
scope: [websocket, isolate, http]
---

# C-27 — "Keep calling on one connection" on the other three transports

The battery that found the http2 caller killing its own connection after 4 calls
(`../lessons/L-08-a-per-test-connection-hides-it.md`) was run against every other
transport. **All clean — do not re-run.**

Same shape each time, on ONE connection: 60 sequential calls, 10 concurrent
rounds, 10 server-streams.

```
  websocket    60/60    10/10    10/10
  isolate      60/60    10/10    10/10
  http/1.1     60/60    10/10    n/a (unary only)
```

Every per-stream counter back at zero afterwards.

## Control

**The control is http2, run with the identical battery** — which is what makes
this a negative rather than three runs that happened not to fail. The same loop
on the same shape, against the transport that had the defect:

```
  http2, before the fix     4/40 sequential, then "Connection is being
                            forcefully terminated. (errorCode: 1)"
                            0/8 concurrent
  http2, after (29d4a7b8)  40/40 and 8/8
  websocket / isolate / http1.1   clean on the first run, no fix needed
```

So the battery demonstrably detects the defect it was looking for; the three
transports above are clean because they do not have it, not because the
measurement is blind.

**And the reason is structural, which is what makes this a durable negative
rather than a lucky run.** The channel-based transports never write on the
release path, and their `finishSending` is already idempotent through
`_finishedStreams`. The http2 caller was the odd one out because it alone had a
`sendData` in `releaseStreamId`. A new transport that writes anything on release
is back in scope.

Related: the missing ceiling found in the same area and fixed next
(`0e8b5d0f`) — `RpcHttp2CallerTransport.createStream` had no `maxActiveStreams`
check at all, so a client configured with 5 opened **500** concurrent streams.
Count over ids RESERVED at `createStream`, never over `_activeStreams`, which
only fills at `sendMetadata` — a burst all passes before the first arrives.
