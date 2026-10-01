---
status: closed (round 584)
round: 584
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b150_what_the_documented_setup_admits.dart
reason: "CONFIRMED on the policy half and fixed: 256 MiB resident, RSS +524, against +37 with a policy. The bodyReadTimeout half is a different question and is B-223"
---

# B-150 — the standalone HTTP/1.1 responder defaults to no body limit and no slow-client bound

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`RpcHttpResponderTransport()` defaults `securityPolicy` to null — any body size, no `maxActiveStreams` — and the class example uses that default; `RpcHttpServer.bodyReadTimeout` defaults to null and dart:io's idle timeout does not cover a slow body.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:60-61, 130-136, 212-217`;
`rpc_http_server.dart:95`.

## Why it matters

The documented setup is the unsafe one.

## Witness a round would build

Read; one 1 GiB upload against the documented example.

## Fix sketch

Default to `const RpcSecurityPolicy()` and a finite body timeout; opt out
explicitly.

## Measured — round 584

The lead asks for one large upload and the STATUS cannot answer it: the pipeline
reads `securityPolicy`, the non-null getter, so an over-size body is refused
either way. What differs is where, and by then the transport's `BytesBuilder` has
all of it. So `P-204` measures RESIDENCY, 256 MiB as one declared frame:

```
CONTROL  const RpcSecurityPolicy(), measured FIRST   413   RSS +37 MiB
WITNESS  the policy parameter OMITTED                200   RSS +524 MiB
CONTROL  the same policy again, measured LAST        413   RSS  +0 MiB
```

**CONFIRMED.** Both orders, because RSS does not come back down between arms and
without the trailing control "the second arm inherited the first's heap" explains
the difference.

The sharpest form of it is inside one file: the same class's RESPONSE side reads
the non-null getter, so the response was bounded and the request body was not.
Four checks sat behind the one `if (policy != null)` — `maxActiveStreams`, the
method path, the metadata block, the body.

Fixed as the sketch's first half says, and the remedy already existed:
`RpcHttpServer` has defaulted the same parameter to `const RpcSecurityPolicy()`
all along, with the doc sentence to go with it. After, with the parameter omitted:
`413, RSS +27`. `securityPolicy: null` still reads `200, RSS +454`, which is the
opt-out doing what it says.

## The second half is NOT closed with this lead

`bodyReadTimeout` still has no default. The documented objection to giving it one
does not hold as written — the `Expect: 100-continue` hazard is about a SHORT
budget:

```
bodyReadTimeout 500 ms, client waited 1 s   HTTP/1.1 408 Request Time-out
bodyReadTimeout  30 s, client waited 1 s   HTTP/1.1 200 OK
```

What does hold is a reason the doc does not state: the knob bounds the WHOLE read,
so a finite default refuses an honest slow upload at the same deadline it refuses
slowloris. The bound that separates them is per-chunk idle, which is a mechanism
rather than a default. `B-223`.

## What this lead does NOT cover

`maxActiveStreams` and the method path came on with the same `if` and are not
driven by any arm; the suite witnesses the body and the metadata block.

## Owner decision

—
