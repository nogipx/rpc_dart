---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/framed_body_survives_unchanged.dart
round: 455
commit: 3087c6ba
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-107 — does a body that looks framed survive unchanged?

## Why it exists

B-78 asks whether the payload reaching `ensureGrpcFrame` can be chosen freely.
The answer is a byte-level one, so the bench has to construct the input rather
than hope to observe it.

## What reading established first, and why it mattered

`ensureGrpcFrame` is called on the OUTPUT of `RpcMessageParser` at both call
sites, and the parser emits de-framed BODIES (`result.add(payload)`,
`parser.dart:269`). Without that, the arm would be guesswork about what the input
is; with it, the input is known to be an application message body.

## The harness

A raw `ServerSocket` speaking HTTP/2 by hand — SETTINGS, its ACK, response
headers, one DATA frame, then trailers with `grpc-status: 0` — answering a real
`RpcHttp2CallerTransport`.

The body is sent with ONE level of framing, which is what a conforming peer does:
the parser strips it and hands the body to the function under test.

**Measured at the TRANSPORT boundary, not through a contract.** The payload the
transport hands upward IS what the function returned, with no codec in between —
and an attempt to read it through a handler failed first, because there is no
`RpcBytes` message type to carry arbitrary bytes.

## The numbers (round 455)

```
                              before fix            after fix
body 13B, first byte 0x00     13B  UNCHANGED        18B  RE-FRAMED
body 13B, first byte 0x99     18B  RE-FRAMED        18B  RE-FRAMED
```

The payload head after the fix reads `00 00 00 00 0d ...` — an outer header
declaring 13 bytes, with the body's own bytes intact behind it.

## Measures

The LENGTH of the payload delivered on `transport.incomingMessages`. Re-framed is
`body.length + 5`; returned unchanged is `body.length`. Length alone separates the
two outcomes, which is why the arms use the same body length.

## Control

A body of the SAME length whose first byte is `0x99` — not a valid compression
flag, so `parseHeader` throws and the heuristic could never fire on it. It reads
`body + 5` before and after. Without it, "the crafted body was re-framed" is
equally consistent with the function re-framing everything for some other reason.

## What it establishes, and what it does not

Establishes: the heuristic was reachable from an ordinary application message, and
it silently turned a 13-byte message into an 8-byte one.

Does not establish how OFTEN a real body satisfies it. The arm constructs the
input deliberately; the probability that, say, CBOR output begins with a valid
flag byte and a length field matching its own remainder was not estimated, and the
fix does not depend on it.
