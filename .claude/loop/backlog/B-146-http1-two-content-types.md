---
status: closed (round 582)
round: 582
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b146_two_content_types.dart
reason: "CONFIRMED in the code's own output (2 values) and REFUTED on the wire (dart:io keeps the last); fixed, and the wire-visible half is that a +json caller was told the bare form"
---

# B-146 — HTTP/1.1 responder emits two content-type values

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-low**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The header map starts with `application/grpc+proto` and the pipeline's initial metadata adds `application/grpc`, merged into a list; dart:io keeps the last, other adapters may emit two lines; the `+proto` ignores what was requested.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:502, 511-521`.

## Why it matters

Ambiguous responses through non-dart:io shelf adapters and proxies.

## Witness a round would build

Serve through `shelf`'s test handler; inspect `Content-Type` values.

## Fix sketch

One content-type, echoing the request's subtype.

## Measured — round 582

The lead's prescribed instrument is right and not sufficient. `P-202` reads both
sides of the adapter, pre-fix:

```
HANDLER  application/grpc        2  [application/grpc+proto, application/grpc]
HANDLER  application/grpc+json   2  [application/grpc+proto, application/grpc]
WIRE     application/grpc        1  [application/grpc]
WIRE     application/grpc+json   1  [application/grpc]
```

Clause by clause:

```
the map starts with +proto, the metadata adds the bare form,
  merged into a list                      CONFIRMED   2 values
dart:io keeps the last                    CONFIRMED   WIRE 1, and the kept
                                                      value is the bare form
other adapters may emit two lines         UNMEASURED  shelf_io is the only
                                                      server adapter here
the +proto ignores what was requested     CONFIRMED in the map, and MOOT on
                                                      dart:io, which discards
                                                      that value
```

**The consequence a peer actually had is none of the four**: a `+json` caller
was told `application/grpc`. Legal, since the subtype is optional, and it tells
the caller nothing about the encoding it asked for.

Fixed as the sketch says, with the transport owning the header: `content-type` is
resolved from the request and any copy in the response metadata is skipped. The
subtype is REBUILT rather than echoed — the 415 gate above checks only the
`application/grpc` prefix, so the remainder is peer input arriving in a response
header; a non-token subtype or a `; charset=` parameter degrades to the bare
form.

After: `HANDLER`/`WIRE` both `1`, and `+json` for a `+json` call.

## What this lead does NOT cover

`_reject` builds its own `Response` for 415, 400, 408 and 503 with no
`content-type` of its own. That is the refusal path, RPC-22's subject, and it was
not read here.

## Owner decision

—
