---
file: packages/core/rpc_dart/.dart_tool/probe/what_a_caller_ceiling_is_for.dart
round: 463
commit: fbbf627f
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-112 — what a caller-side ceiling is for

## Why it exists

B-75 says the HTTP/1.1 caller never reads `maxActiveStreams`, and round 451's
re-read says the first question is not "why is it missing" but "what is a
CALLER-side ceiling for at all" — with a counter-hypothesis attached: the
`HttpClient` connection pool may already bound concurrency there, making the
limit meaningless rather than missing.

Both halves are measurable in one run, and neither is answerable by reading.

## The harness

Twelve concurrent unary calls against a handler that PARKS, with
`maxActiveStreams: 4` on the caller and `1024` on the responder — so a refusal
can only be the caller's own ceiling. One arm per caller transport: core's
channel pair, HTTP/2, HTTP/1.1.

**The parked handler is what makes the ceiling observable.** With a handler that
returns, calls retire faster than they are issued and twelve of them never hold
four slots at once; the ceiling is then never reached and every transport reads
the same.

Two further arms:

- **sequential**, `4 x 3` calls each finishing before the next starts. This is
  RPC-05's third canary made into an arm: a ceiling charged and never released
  passes the concurrent test and then refuses ordinary traffic forever.
- **the endings**, four of them — completion, connection refused, HTTP 503, and
  a 200 that is not gRPC — each run past the ceiling, reporting `activeStreams`
  from `health()` afterwards.

## Measures

Three per arm, and the third is what answers the pool hypothesis:

- admitted / refused, and the refusal's status and message;
- peak CONCURRENT HANDLER entries, counted inside the contract handler — the
  thing a ceiling is supposed to cap, on the far side of the wire, rather than a
  proxy for it. A count of returned futures cannot tell a refusal from a slow
  success;
- for HTTP/1.1, peak concurrent requests open AT THE SERVER, counted in a shelf
  wrapper around the responder's handler. This is the pool hypothesis measured
  rather than argued.

Plus `health().details['activeStreams']` after each ending arm, which is what
makes a ratchet visible without waiting for a user to hit it.

## The numbers (round 463)

```
                    admitted  refused  peak handlers  peak server requests
core (channel)         4         8           4
http2                  4         8           4
HTTP/1.1 before       12         0          12                12
HTTP/1.1 after         4         8           4                 4
```

Refusal on all three, after: `status=8 Too many active streams: 4 (max: 4)`.

**The pool hypothesis is refuted, and not marginally**: all twelve requests were
open at the server simultaneously. `dart:io`'s `maxConnectionsPerHost` defaults
to unlimited, so nothing was bounding anything.

Sequential, all three transports: `ok=12/12`, and
`health().details['activeStreams']` back to `0`.

## Control

- **The two siblings are the control for the outcome.** Same ceiling, same
  burst, same parked handler, and they admit exactly 4 — so 12 is the transport
  and not the bench.
- **A high ceiling is the control for the refusal.** The same twelve calls with
  `maxActiveStreams: 64` are all admitted, so the refusal is the ceiling rather
  than the burst, the parked handler or the server.
## What it establishes, and what it does not

Establishes: the ceiling is REACHABLE and was inert; the pool does not cover for
it; the fix brings HTTP/1.1 to the siblings' numbers exactly; and the slot is
given back on all four endings — measured with the second release site ABLATED,
which is how that site is known to be redundant today rather than assumed to be
needed.

Does NOT establish anything about the streaming shapes: every arm is unary. The
charge point is `createStream()`, which every shape goes through, but the
ENDINGS differ and only the unary ones were driven.
