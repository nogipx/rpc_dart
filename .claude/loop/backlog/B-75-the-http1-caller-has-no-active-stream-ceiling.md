---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: —
reason: cost — split out of B-70 item 18; RPC-05 and C-29 may already have written up the charge point
---

# B-75 — the HTTP/1.1 caller has no active-stream ceiling at all

Three transports, three different answers, and one of them is an absence:

```
  rpc_http_caller_transport.dart   NO maxActiveStreams check — zero references
  channel_transport.dart           bounds _activeStreams (:395), removes at
                                   :408 and :800
  rpc_http2_caller_transport.dart  bounds _reservedStreams (:732), removes at
                                   :791, :936, :1184 — then applies a SECOND
                                   ceiling to _streamParsers at :1362
```

The sharpest half is the simplest: the HTTP/1.1 caller does not reference the
limit anywhere, so a policy that bounds concurrency on every other transport
bounds nothing there.

**Read RPC-05 and C-29 FIRST.** The charge point for this limit has been worked
over repeatedly — C-29 is "the real scope of the stream limits" and RPC-05 is
the lens about where a concurrency limit is charged. It is possible that the
HTTP/1.1 shape makes the limit meaningless rather than missing, and that is the
first question, not the fix.

If it is genuinely missing, the canary is RPC-05's own A1: both neighbours of
the right charge point are usually wrong, and the tests must fail DIFFERENTLY
for each wrong choice.

## Owner decision

—
