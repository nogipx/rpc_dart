---
file: packages/core/rpc_dart/.dart_tool/probe/cbor_amplification_e2e.dart
round: 783
commit: 8471b02c
paths: [packages/core/rpc_dart/lib/src/codec/special_cbor.dart, packages/core/rpc_dart/lib/src/codec/codec.dart, packages/core/rpc_dart/lib/src/endpoint/middleware.dart]
status: valid
---

# P-278 — cbor decode cost per wire byte

## Measures

Two benches, both AOT-compiled, peak memory from `/usr/bin/time -l`.

`cbor_decode_amplification.dart <arm> 16` calls `CborCodec.decode` on a
16 MiB `{"a": <payload>}`. Arms: one byte string (`bytes`), an array of
`0x00` (`smallInts`), of `0x80` (`emptyArrays`), of `0xA0` (`emptyMaps`).

```
  arm           heap growth   per wire byte   decode
  bytes         +16 MiB       1.0             2 ms
  smallInts     +208 MiB      13.0            191 ms
  emptyArrays   +675 MiB      42.2            880 ms
  emptyMaps     +1148 MiB     71.8            1047 ms
```

`cbor_amplification_e2e.dart <arm> <k>` sends `k` such calls through
`RpcChannelTransport.pair()` with `RpcDataTransferMode.codec` to a responder
with the default policy, a contract using `RpcCodec(RpcString.fromJson)`
through a counting wrapper, and one interceptor that throws UNAUTHENTICATED
for every call.

```
  arm          k   process max rss   took      decodes   answer
  bytes        1   75 MiB            7 ms      1         UNAUTHENTICATED
  emptyMaps    1   1309 MiB          979 ms    1         UNAUTHENTICATED
  bytes        4   155 MiB           19 ms     4         UNAUTHENTICATED
  emptyMaps    4   1413 MiB          3557 ms   4         UNAUTHENTICATED
```

Round 785 added a third argument, `plain` or `gzip` (the caller's
`compressionEnabled`), and a listener on the server transport printing the
payload bytes received and the request's `grpc-encoding`:

```
  arm                 on the wire   encoding   max rss    took
  emptyMaps, plain    16383 KiB     -          1269 MiB   1136 ms
  emptyMaps, gzip     15 KiB        gzip       1296 MiB   1021 ms
  bytes, gzip         15 KiB        gzip       92 MiB     57 ms
```

## Control

`bytes`: the same wire size, the same call path, the same refusal; only the
payload's item count differs (one item against 16 million). A timer sampling
RSS every 20 ms in the e2e bench never fired during a decode: the decode is
synchronous on the responder's isolate.
