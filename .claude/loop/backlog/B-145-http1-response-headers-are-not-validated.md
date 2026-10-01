---
status: closed (round 581)
round: 581
commit: 7346064e
release: breaking
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
probe: P-201
reason: "bench — CONFIRMED at its medium-LOW confidence: 1007 headers delivered on a `maxHeaders` of 128, because this transport is not an `RpcChannelTransport` and core's `_validateInbound` never runs on it. Fixed, with the shared rule moved to one home in `RpcSecurityPolicy.statusOnly`"
---

# B-145 — HTTP/1.1 caller passes response headers into metadata unchecked

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-low**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Core validates peer metadata in `_validateInbound`; the HTTP caller builds `RpcMetadata` from response headers with no count, size or character checks.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:433-476`.

## Why it matters

The security policy is one-directional on this transport.

## Witness a round would build

Response with 1000 headers or a CR in a value (raw server).

## Fix sketch

Run `validateMetadata` on the converted response metadata.

## Outcome (round 581) — confirmed, and the fix needed two tries

`../rounds/581-the-policy-that-ran-one-way.md`. Bench `P-201`.

```
                                         before   after
WITNESS  1000 extra response headers      1007      2     grpc-status 9 throughout
CONTROL  2 extra response headers            9      9
```

**1007 against a `maxHeaders` of 128**, and the cause is structural: this transport is its own
`IRpcTransport`, not an `RpcChannelTransport`, so the one place that validates inbound metadata belongs to a
class it is not. The REQUEST direction was already checked (`sendMetadata`, `:323`) — the response was not.

**The first fix reproduced the defect it was guarding against.** Reducing an offending frame to its status is
right for a TRAILER and wrong for an INITIAL frame, because this transport routes `grpc-status` into the
trailers — so an initial frame has no status to keep, and answering it with this side's INVALID_ARGUMENT put
a manufactured status AHEAD of the server's real 9: `headers delivered 4, grpc-status 3`. An offending
initial frame is now reduced to nothing and the trailers answer the call.

**One home for the rule.** `RpcSecurityPolicy.statusOnly` now owns what a caller keeps from metadata that
breaks the policy, carrying round 567's measurement; core's `_statusOnly` and the http2 caller's
`_peerStatusOnly` both delegate to it. Round 567 had left two copies and this would have been a third.

Not established: a character violation (a `dart:io` `HttpServer` will not emit a CR in a value, and
`isValidHeaderValue` is the same check on every path), the responder half's own response path, and any
reachable ATTACK — the server here is one the caller chose to talk to, so what the round shows is the
asymmetry the lead names.

## Owner decision

—
