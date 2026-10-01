---
status: closed (round 585)
round: 585
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b148_what_a_buffered_request_costs.dart
reason: "CONFIRMED at its high confidence and fixed: the buffer's own cost for a 32 MiB body was +205 MiB and is now +0, with a bare List<int> and a bare BytesBuilder as the bracket"
---

# B-148 — HTTP/1.1 caller buffers the request body in a `List<int>` and copies it again

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`bodyBuffer.addAll(data)` into a growable `List<int>` (a slot per byte), then `Uint8List.fromList` — the responder already moved to `BytesBuilder(copy: false)` and explains why.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:15, 315, 352`; compare
`rpc_http_responder_transport.dart:33-41, 333-337`.

## Why it matters

8x memory per request byte on the VM, plus a copy.

## Witness a round would build

Allocation for a 10 MiB request.

## Fix sketch

`BytesBuilder(copy: false)`.

## Measured — round 585

An allocation number alone says nothing, so `P-205` runs the library's buffer
beside two bare ones that bracket it. 32 MiB, with RSS read before the payload
exists, after it exists, and after the buffer has taken it:

```
LIBRARY   the buffer's own  +205 MiB
LIST      +165 MiB
BUILDER     +1 MiB
```

**CONFIRMED** — the library sat with `List<int>`. After the fix its arm reads
`+0 MiB`.

The bare arms are a BRACKET and not a ratio: `LIST` read `+165` in one run and
`+528` in the next on identical input, because RSS for a growable list depends on
the heap's state. What they establish is which of the two the library matches.

Fixed as the sketch says. `takeBytes()` on a single-chunk buffer returns that
chunk, so every unary call's body now reaches `bodyBytes` with no copy at all —
pinned in the suite as `identical(sent, payload)`, which is the same fact a test
can assert without measuring memory.

## What this lead does NOT cover

- Time. `Uint8List.fromList` over a 32 MiB list of word-sized elements costs CPU
  as well as memory; the lead filed the memory claim.
- The multi-chunk path still copies once at fire time, because `takeBytes()`
  concatenates. One copy instead of two plus the list; only a client stream pays
  it, and the remedy would be to hand `package:http` a stream, which loses the
  content-length this transport sets.
- The hand-over is a new requirement on callers and nothing enforces it: mutating
  the payload after `sendMessage` now changes the wire. Same contract the channel
  transports have since round 575.

## Owner decision

—
