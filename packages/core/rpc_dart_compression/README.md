<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_compression

Cross-platform compression codecs for `rpc_dart`.

`rpc_dart` negotiates per-message compression through the gRPC
`grpc-encoding` / `grpc-accept-encoding` headers, but the built-in gzip is
VM-only (`dart:io`). On dart2js and Wasm no codec is registered, so a peer that
sends gzip is refused with `UNIMPLEMENTED`. This package provides a gzip codec
that works on every target.

- `RpcGzipCodec` — gzip implemented over the `archive` package, no `dart:io`.
- `RpcGzipCodec.register()` — installs it into the core compression registry.

## Install

```yaml
dependencies:
  rpc_dart_compression: ^0.2.0
```

## Setup

Register once at startup, before creating endpoints, on both peers:

```dart
import 'package:rpc_dart_compression/rpc_dart_compression.dart';

void main() {
  RpcGzipCodec.register();
}
```

`register()` is shorthand for:

```dart
RpcGrpcCompression.register(RpcGrpcCompression.gzip, const RpcGzipCodec());
```

The registry (`RpcGrpcCompression`) is global and maps an encoding name
(case-insensitive) to a codec. Registering a name again replaces the previous
codec, so on the VM this also replaces the built-in `dart:io` gzip.
`RpcGrpcCompression.unregister('gzip')` removes it.

Registration only makes the encoding available. A caller compresses its
requests, and advertises the registered encodings so responses come back
compressed, only when its endpoint is created with `compressionEnabled: true`
(`RpcCallerEndpoint` or `RpcPeerEndpoint`; the default is `false`):

```dart
RpcCallerEndpoint compressedCaller(IRpcTransport transport) {
  return RpcCallerEndpoint(transport: transport, compressionEnabled: true);
}
```

Compression is skipped entirely on transports with `supportsZeroCopy == true`,
and a message is sent compressed only when that makes it smaller. The full
negotiation rules are in the `rpc_dart` Agent Skill
(`skills/rpc_dart-core/references/codecs-and-compression.md`).

## Compression level

`level` is the gzip level, `0` (store) to `9` (smallest output, slowest). The
default is `6` (`RpcGzipCodec.defaultLevel`); `fastestLevel` (1) and `bestLevel`
(9) are also provided.

```dart
RpcGzipCodec.register(level: RpcGzipCodec.bestLevel);
```

## Decompression limits

`maxDecompressedSize` bounds what a compressed message may inflate to:

```dart
RpcGzipCodec.register(maxDecompressedSize: 16 * 1024 * 1024);
```

The effective limit is the smaller of this value and the per-message limit the
core passes in as `maxOutputBytes`
(`RpcSecurityPolicy.maxMessageLengthBytes`). Going over
it throws `RpcStatusException(RpcStatus.resourceExhausted, ...)`; malformed gzip
input throws `FormatException`, which the core reports as `INTERNAL`.

Below the limit, the check is free — gzip stores the uncompressed size in its
ISIZE trailer, so an oversized payload is refused before anything is allocated.

**Where the guard behaves differently per target.** ISIZE is the size modulo
2^32, so a payload inflating to `k*2^32 + small` declares `small` and clears
that pre-check. What happens next is not the same everywhere:

| target | after the pre-check |
| --- | --- |
| VM | aborts the inflate the moment the output passes the limit |
| dart2js, Wasm | inflates the whole output, then refuses it |

`package:archive` materialises the entire output before handing it over, so on
web there is nothing to interrupt. The limit still holds — nothing over it is
ever returned — but the refusal costs the full allocation and the event-loop
time first. `test/audit/isize_understates_on_web_test.dart` measures the
difference.

This is not configurable, and lowering `maxDecompressedSize` does not remove it —
it only changes the size of what a hostile peer can make you spend. Treat the
limit as a bound on what you accept, and on web assume refusing is not free.

## Custom codecs

Any algorithm can be added by implementing `RpcCompressionCodec` and
registering it under its encoding name. Both peers must register it; a caller
that declares an encoding the responder lacks gets `UNIMPLEMENTED`.

`decompress` must stop and throw `RpcStatusException(RpcStatus.resourceExhausted,
...)` before producing more than `maxOutputBytes` (when non-null). Anything else
it throws is treated as malformed input (`INTERNAL`).

```dart
final class BrotliCodec implements RpcCompressionCodec {
  const BrotliCodec();

  @override
  Uint8List compress(Uint8List data) => brotliEncode(data);

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) {
    final out = BytesBuilder(copy: false);
    for (final chunk in brotliDecodeChunks(data)) {
      out.add(chunk);
      if (maxOutputBytes != null && out.length > maxOutputBytes) {
        throw RpcStatusException(
          RpcStatus.resourceExhausted,
          'Decompressed message exceeds $maxOutputBytes bytes',
        );
      }
    }
    return out.takeBytes();
  }
}

void registerBrotli() {
  RpcGrpcCompression.register('br', const BrotliCodec());
}
```

`brotliEncode` and `brotliDecodeChunks` stand for your implementation; decode
lazily, chunk by chunk, so the limit fires before the output is allocated.
