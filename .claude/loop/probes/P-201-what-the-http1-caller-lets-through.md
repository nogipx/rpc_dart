---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b145_response_headers_unchecked.dart
round: 581
commit: 7346064e
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-201 — what does the HTTP/1.1 caller let through?

## Why it exists

B-145 says the policy is one-directional on this transport. The lead's witness line asks for "a response
with 1000 headers or a CR in a value (raw server)"; the count is the half a `dart:io` `HttpServer` can
produce, and it is enough — `maxHeaders` is 128.

**It reads TWO things, and the second is why**: how many headers got through, AND whether the server's
`grpc-status` survived. Round 567 established that validating a peer's trailers too strictly destroys that
status, so a probe measuring only the count would have called the first fix a success.

## The harness

A `dart:io` `HttpServer` answering `200`, `content-type: application/grpc+proto`, N headers of noise, a real
`grpc-status: 9` with a message, and one gRPC frame as the body. The transport is driven directly —
`createStream`, `sendMetadata`, `sendMessage(endStream: true)` — and the arm counts the headers across every
metadata frame delivered, keeping the FIRST status it sees.

First-status-wins is the load-bearing detail: a status manufactured on the initial frame arrives ahead of
the trailers, and a probe that recorded the LAST one would not have noticed.

## The numbers (round 581)

Before:

```
WITNESS  1000 extra response headers   headers delivered 1007, grpc-status 9
CONTROL  2 extra response headers      headers delivered    9, grpc-status 9
```

First attempt at the fix:

```
WITNESS  headers delivered 4, grpc-status 3    <- our status, ahead of the server's
```

After:

```
WITNESS  headers delivered 2, grpc-status 9
CONTROL  headers delivered 9, grpc-status 9    unchanged
```

## Measures

Headers delivered to the application, summed across the response's metadata frames, and the first
`grpc-status` seen. Both, because either alone admits a wrong fix.

## Control

**Two extra headers, conforming.** It reads `9 / 9` before and after, so the witness's collapse to 2 is the
policy acting on an over-decorated response and not the transport having stopped delivering metadata.

The middle reading above is kept in this record as the control that caught the first fix: `grpc-status 3`
is what "reduced to its status" does to a frame whose status lives somewhere else.

## What it establishes, and what it does not

Establishes that the response path applied no count, size or character check, and that applying one
reduces an over-decorated response to the status the server actually sent.

Does NOT drive a character violation. `HttpServer` will not emit a CR inside a value, and
`isValidHeaderValue` is the same check on this path as on every other.

Does NOT model an attacker. The server here is one the caller chose to talk to; what the arm shows is the
ASYMMETRY the lead names, not a reachable attack.

## Reading

rpc_dart_http — a `dart:io` server answering a real `grpc-status: 9` plus N
headers of noise: `1000 extra -> 1007 delivered` against a `CONTROL 2 extra ->
9`, now `2`. **It reads TWO things and the second is why it exists**: the
header count AND whether the server's status survived — a probe measuring only
the count would have called the first fix a success, when it read `headers 4,
grpc-status 3`. First-status-wins is load-bearing: a status manufactured on
the initial frame arrives ahead of the trailers, and recording the LAST one
would have missed it. Does NOT drive a character violation (`HttpServer` will
not emit a CR in a value) and models no attacker
