---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r840_pinned_body.dart
round: 840
commit: 5598db22
paths: [packages/transport/rpc_dart_http/lib/src/body_accumulator.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
promoted: packages/transport/rpc_dart_http/test/a_body_chunk_cannot_pin_its_read_buffer_test.dart
---

# P-311 — chunk views pin read buffers

`fvm dart run <file> <pad bytes> [connections]` from the repo root. The
server (`RpcHttpServer`, `maxMessageLengthBytes: 8 MiB`) runs in a child
process, so its RSS holds no attacker buffers; it prints its peak RSS. Each
connection sends a chunked body of 4096-byte chunks, each with a chunk
extension of `pad` bytes, up to just under the limit, and never ends it.

## Measures

Bytes the server's body accumulators hold (distinct buffers kept, each once),
against the body bytes the limit counts. Read in round 840 from temporary
counters in `BodyAccumulator`, since stripped; the peak RSS of the server
process is printed alongside and is noisier (it includes garbage).

## Control

`pad 0`: the same body bytes with no extension. Before the fix:

```
arm               counted    sent      held       server RSS peak
pad 0, 3 conn     23.8 MiB   23.9 MiB  23.9 MiB   +30.3 MiB
pad 60000, 3 conn 23.8 MiB   372.7 MiB 372.6 MiB  +458.0 MiB
pad 60000, 1 conn  7.9 MiB   124.2 MiB     -      +136.7 MiB
```

Instrument trap: `Uint8List.buffer` returns a new wrapper per call on the
VM, so an identity set counts every chunk; `ByteBuffer ==` compares the data.
