---
status: closed (round 701)
round: 701
commit: feaf34de
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/peer_responder_icpt_context.dart
reason: "owner decision — a deadline a responder interceptor sets is visible to the handler and enforced by nothing; the same deadline set by a caller interceptor is enforced. Whether the responder should enforce it, and in which direction, is what the field means on that side"
---

# B-244 — a deadline set by a responder interceptor is not enforced

## Seen (owner review after round 659)

The responder arms the stream's deadline timer once, while building the
context from the inbound message (`responder_pipeline.dart:2305`), before any
interceptor runs. A responder interceptor that hands `next` a context from
`withTimeout` / `withDeadline` changes what the handler reads and nothing else.
The caller side is the opposite: an interceptor's deadline goes on the wire as
`grpc-timeout` and both ends enforce it.

```
caller interceptor, 200 ms     caller DeadlineExceeded at 196 ms, handler token cancelled 198 ms
responder interceptor, 200 ms  handler deadline=true; token NOT cancelled after 2 s; caller got "late" at 2018 ms
control: caller sets 200 ms    caller DeadlineExceeded at 183 ms, handler token cancelled 184 ms
```

Probes: `peer_middleware_context.dart dl` (caller arm),
`peer_responder_icpt_context.dart dl` / `dlctl`.

## Severity

What is lost: a server-side timeout written as an interceptor -- the obvious
place for one -- silently does nothing; the handler runs until the client's own
deadline, or for ever if the client sent none. Reachable with ordinary API, no
peer misbehaviour. Medium.

## Options

1. **Tighten only.** Where the interceptor chain hands the handler its context
   (round 659's `_keepCancellable` point in `base_endpoint.dart`), a deadline
   EARLIER than the one armed re-arms the stream's timer; a later one or none
   leaves the client's in force. A responder can shorten a call, never extend
   what the caller asked for. Matches the caller side. Needs the endpoint base
   to reach the responder's stream state, which today only the pipeline holds.
2. **Leave it, documented:** a responder interceptor's deadline is advisory --
   the handler sees it via `deadline` / `isExpired`, no timer enforces it.
3. **Take whichever the interceptor set**, later included. The caller times out
   on its own anyway, so extending buys nothing but a handler that outlives
   its caller.

Recommended: 1 (the owner's choice of recommendation in the review).

## Outcome (round 701)

FIXED as decided: an EARLIER deadline from a responder interceptor re-arms the
stream's timer; a later one or none keeps the caller's. Before, a 200 ms
interceptor timeout let the handler answer 'late' after 2 s.
`../rounds/701-a-responder-interceptor-can-shorten-a-call.md`.

## Owner decision

2026-10-07: **option 1, tighten only**.
