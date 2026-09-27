---
status: decided by owner (round 445)
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

## Two corrections before anyone benches this (round 451, a read)

**1. The HTTP/1.1 package DOES enforce `maxActiveStreams` — on the responder.**
`rpc_http_responder_transport.dart:219` checks `_pending.length >=
policy.maxActiveStreams`, and its doc at `:88` says so outright: *"This transport
enforces `maxActiveStreams`, the method path, metadata and ..."*. The absence is
caller-side only, and the lead's table does not say that.

**2. C-29 says what the limit is FOR, and it is not a caller self-limit.**
*"Responder endpoints are PER CONNECTION — except on HTTP/1.1 … a peer pins
roughly `maxActiveStreams x 33 KiB` per connection it opens."* The limit is a
defence against a peer. On that reading the HTTP/1.1 caller having no ceiling is
not a gap at all, and neither is the shape of the table: core's channel transport
bounds `_activeStreams` for a class that serves BOTH roles, so its bound covers
the responder role too.

**So the round's first question is not "why is it missing here" but "what is a
CALLER-side ceiling for at all".** http2's caller does bound `_reservedStreams`,
which is the one genuinely caller-side instance, and whether that protects
anything a user would notice is unmeasured. If it does not, the finding inverts:
the limit should be documented as responder-scoped and http2's caller-side bound
is the odd one out.

The neighbouring measurement, if the answer is "yes, callers should be bounded":
the HTTP/1.1 caller is already bounded by its `HttpClient` connection pool, so the
ceiling may be unreachable rather than absent.

## Owner decision

**Measure first, then apply uniformly.** One line for the whole class —
B-75, B-79 and B-80 all got the same call.

1. Read RPC-05 and C-29 before anything, then answer whether the limit is
   MEANINGFUL on the HTTP/1.1 caller. Each call there is its own request and
   concurrency is already bounded by the `HttpClient` connection pool, so the
   limit may be meaningless rather than missing.
2. If it is meaningful: charge it at the same point as core and http2, and put
   the new refusals in the CHANGELOG — a policy that silently does not apply on
   one transport is the worse failure, so consistency wins over not adding a
   refusal.
3. If the HTTP/1.1 shape makes it meaningless: close as a negative in `checked/`
   plus one doc line saying so. That is a result, not a non-result.

DECLINED: mapping the policy onto `maxConnectionsPerHost` (turns the limit into
a queue on one transport and a refusal on the others — the same disagreement
this lead is about), and documenting it as unsupported without measuring (leaves
the user believing they bounded something).
