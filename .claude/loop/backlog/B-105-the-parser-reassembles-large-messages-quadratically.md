---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/core/parser.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-105 — RpcMessageParser copies the whole unconsumed tail on every chunk

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

While a message body is incomplete, each chunk costs `compact()` (copy the tail) plus `addBytes` (copy tail + chunk) — O(N^2/C) for an N-byte message in C-byte chunks: a 16 MiB message in 16 KiB DATA frames is ~1024 growing copies, gigabytes of memcpy; http2 feeds the parser exactly like that.

## The shape

`packages/core/rpc_dart/lib/src/core/parser.dart:36-50`:

```dart
void addBytes(Uint8List data) {
  if (readOffset == _bytes.length) {
    _bytes = Uint8List.fromList(data);          // comment says "reuse directly"
  } else {
    final merged = Uint8List(unconsumed + data.length);
    merged.setRange(0, unconsumed, _bytes, readOffset);
    ...
```

and `compact()` (`:60-65`) copies `_bytes.sublist(readOffset)` at the end of every
call. The header is read through a 5-byte `sublist` per message (`:190-195`). The
journal never examined this (`grep addBytes|quadratic` over `.claude/loop` is
empty apart from a lens).

## Why it matters

CPU and allocation blow-up on large messages over http2 (16 KiB frames), and on
any transport that hands the parser partial frames. The channel transports are
spared because `RpcFrameMultiplexedChannel` reassembles first.

## Witness a round would build

Micro-bench: feed a 16 MiB framed message in 16 KiB chunks; time and bytes
allocated. Then the same through an http2 pair, unary, 16 MiB request.

## Fix sketch

Once `expectedMessageLength` is known, allocate the body buffer once and fill it;
keep a list of chunks for the header phase; read the header with a
`ByteData.sublistView`. Also fix the "reuse incoming data directly" comment.

## Owner decision

—
