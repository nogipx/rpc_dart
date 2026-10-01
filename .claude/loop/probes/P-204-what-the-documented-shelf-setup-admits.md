---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b150_what_the_documented_setup_admits.dart
round: 584
commit: f3cc2e53
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
status: valid
---

# P-204 — what the documented shelf setup admits

## Why it exists

B-150 says the documented construction of `RpcHttpResponderTransport` has no
limits, and asks for "one 1 GiB upload against the documented example". The
status alone cannot answer it: the PIPELINE reads `securityPolicy`, the non-null
getter, so an over-size body is refused either way. What differs is where the
refusal happens, and by then the transport's `BytesBuilder` is holding the body.

So the measurement is RESIDENCY.

## The harness

A 256 MiB upload declared as one gRPC frame, streamed from one reused 1 MiB chunk
so the CLIENT's own share of RSS stays flat — the climb measured is the
responder's. `ProcessInfo.currentRss` sampled every 20 ms, reported as a peak
against the baseline taken just before the request.

Four arms, and the third is the one a careless version would omit:

```
CONTROL  const RpcSecurityPolicy(), measured FIRST
WITNESS  the policy parameter OMITTED        <- what the example does
ARM      securityPolicy: null                <- the explicit opt-out
CONTROL  the same policy again, measured LAST
```

**`securityPolicy: null` is not the same arm as omitting it**, and only the second
reads the default. A probe with the null arm alone measures the opt-out and
reports it as the default's behaviour.

**Both orders, because RSS does not come back down between arms.** A single order
leaves "the second arm inherited the first's heap" as a live explanation for the
whole difference; the trailing control reading `+0` is what removes it.

The second half re-measures a documented sentence rather than the code: a raw
socket sends `Expect: 100-continue`, waits one second for the `100 Continue`
dart:io never sends — which is curl's fallback — and only then writes the body.

## The numbers (round 584)

Before:

```
CONTROL  FIRST   413   RSS 255 -> 292 MiB  (+37)
WITNESS  OMITTED 200   RSS 287 -> 811 MiB  (+524)
CONTROL  LAST    413   RSS 757 -> 757 MiB  (+0)
```

After:

```
CONTROL  FIRST   413   RSS 245 -> 294 MiB  (+49)
WITNESS  OMITTED 413   RSS 292 -> 319 MiB  (+27)
ARM      null    200   RSS 315 -> 769 MiB  (+454)
CONTROL  LAST    413   RSS 769 -> 769 MiB  (+0)
```

The `Expect: 100-continue` arms, unchanged by the fix:

```
bodyReadTimeout 500 ms, client waited 1 s   HTTP/1.1 408 Request Time-out
bodyReadTimeout  30 s, client waited 1 s   HTTP/1.1 200 OK
```

## Measures

Peak RSS during one 256 MiB upload, and the HTTP status that ends it. The pair,
because the status says which layer refused and the RSS says what was resident
when it did.

## Control

**A conforming policy, measured both before and after the witness.** `+37` first
and `+0` last against the witness's `+524` is what makes the ordering irrelevant.

**The explicit `securityPolicy: null` arm is the control for the fix itself**: it
still reads `200 / +454`, so the default changed and the opt-out did not.

## What it establishes, and what it does not

Establishes that the transport's own checks were off by default, that the body
was fully resident before any layer refused it, and that the documented example
was the construction with them off.

Establishes, on the second half, that the documented objection to a finite
`bodyReadTimeout` default is about a SHORT budget: at 30 s an
`Expect: 100-continue` client is answered 200.

Does NOT measure what a finite default costs a slow but honest upload.
`bodyReadTimeout` is a deadline on the WHOLE read (`readBody().timeout(...)`), so
it cannot separate slow from stalled — that is a reading, and the rig for it is
not here: a client that uploads steadily under a short budget deadlocks this
process at `socket.close()` once the responder has answered and gone. See B-223.

Does NOT drive `maxActiveStreams`, the method path, or the metadata bound, which
sat behind the same `if (policy != null)`. The suite covers the metadata one.
