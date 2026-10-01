---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b146_two_content_types.dart
round: 582
commit: a4c0297c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/core/metadata.dart]
status: valid
---

# P-202 — which content-type a gRPC-over-HTTP/1.1 response carries

## Why it exists

B-146 prescribes its own instrument — shelf's test handler, read before an
adapter can collapse the header — and that instrument is right for what the code
PRODUCES. It cannot see what a peer RECEIVES, and on this defect the two differ,
so the probe reads both.

`Response.headersAll` is shelf's multi-value view, taken straight off the object
`transport.handler` returned. `HttpClient`'s `headers[name]` returns one entry per
field line received, over a real socket under `shelf_io`.

## The harness

One unary echo method, driven twice per view: a request asking for
`application/grpc` and one asking for `application/grpc+json`. The HANDLER arm
calls `transport.handler` directly; the WIRE arm serves the same handler with
`shelf_io.serve` on port 0 and posts to it with `HttpClient`.

The request's content-type is the only variable. It is also peer input, which is
why the second arm exists at all — the 415 gate above `_completeResponse` checks
only the `application/grpc` prefix.

## The numbers (round 582)

Both halves of the fix ablated, which is the pre-round behaviour:

```
HANDLER  application/grpc        2  [application/grpc+proto, application/grpc]
HANDLER  application/grpc+json   2  [application/grpc+proto, application/grpc]
WIRE     application/grpc        1  [application/grpc]
WIRE     application/grpc+json   1  [application/grpc]
```

Fix in place:

```
HANDLER  application/grpc        1  [application/grpc]
HANDLER  application/grpc+json   1  [application/grpc+json]
WIRE     application/grpc        1  [application/grpc]
WIRE     application/grpc+json   1  [application/grpc+json]
```

The left column is what the request asked for.

## Measures

The number of `content-type` values a response carries, at two points: as the
transport built it, and as a peer received it. Both, because either alone grades
the defect wrongly — see `../lessons/L-18-the-lead-names-one-side-of-an-adapter.md`.

## Control

**The plain `application/grpc` request is the control for the subtype half**: it
reads `[application/grpc]` before and after on the wire, so the `+json` arm's
change is the echo and not the transport having changed its bare form.

**The WIRE row is the control for the duplicate half**, in the direction that
refutes: `1` line before the fix is what says `dart:io` already collapsed the
list, so the HANDLER row's `2` is a property of this code and not of any
deployment through that adapter.

## What it establishes, and what it does not

Establishes that the response was built with two values, that `dart:io` keeps the
last of them, and that the value a peer was therefore given ignored the subtype
it asked for.

Does NOT see a non-dart:io adapter. `shelf_io` is the only server adapter in this
repository's dependency set, so "another host may emit two lines" is the half of
B-146 that stays unmeasured; the HANDLER row establishes only that there is
something for such a host to emit.

Does NOT cover `_reject`, which builds its own `Response` for 415, 400, 408 and
503. Every ordinary ending, including the oversized-response answer at
`_answerOversizedResponse`, reaches the one header map in `_completeResponse`, so
the method shape is not a variable here.
