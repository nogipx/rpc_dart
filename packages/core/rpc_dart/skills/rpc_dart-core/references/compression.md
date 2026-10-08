<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Compression with rpc_dart_compression

`rpc_dart_compression` ships one codec, `RpcGzipCodec`: gzip built on
`package:archive`, with no `dart:io`. It runs on the VM, Flutter, dart2js and
Wasm. The core's own gzip needs `dart:io`, so on web no codec is registered
until you add this one.

How compression is negotiated (the `RpcGrpcCompression` registry,
`compressionEnabled`, `grpc-encoding`, custom `RpcCompressionCodec`s) is in
[codecs-and-compression.md](codecs-and-compression.md). This file covers only
what the package adds.

Use it when:

- a web or Wasm build must send or accept gzip. Without a registered codec a
  web caller advertises `identity` only, and a gzip request reaching a web peer
  is refused with `UNIMPLEMENTED`;
- you want to choose the gzip level, or cap decompressed size per codec, on any
  platform.

## Setup

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_compression: ^0.2.0
```

## Rules

- Register once at startup, before creating endpoints, on BOTH peers:
  `RpcGzipCodec.register()`. The registry is global and static.
- `register()` installs the codec under `gzip` (`RpcGrpcCompression.gzip`). On
  the VM it replaces the core's built-in `dart:io` gzip.
- Registration only makes gzip available. The caller compresses requests, and
  asks for compressed responses, only when its endpoint is created with
  `compressionEnabled: true` (`RpcCallerEndpoint` or `RpcPeerEndpoint`). The
  responder needs nothing beyond registration.
- Compression runs only on transports with `supportsZeroCopy == false`. Over
  `RpcChannelTransport.memoryPair()` nothing is compressed; use
  `RpcChannelTransport.pair()` to exercise it in tests.
- `level` is 0 (store) to 9 (smallest, slowest). Default 6. Out of range trips
  an `assert` in debug; release and web builds clamp it to 0..9.
- The decompressed size limit is the smaller of `maxDecompressedSize` and the
  receiving transport's `RpcSecurityPolicy.maxMessageLengthBytes`. Exceeding it
  is `RESOURCE_EXHAUSTED`, and the peer sees that status.

## API

| Member | Meaning |
| --- | --- |
| `const RpcGzipCodec({int level = 6, int maxDecompressedSize})` | The codec. `maxDecompressedSize` defaults to no codec-side cap; the policy limit still applies. |
| `static void register({int level, int maxDecompressedSize})` | Shorthand for `RpcGrpcCompression.register(RpcGrpcCompression.gzip, RpcGzipCodec(...))`. |
| `RpcGzipCodec.defaultLevel` / `fastestLevel` / `bestLevel` | 6 / 1 / 9. |
| `Uint8List compress(Uint8List data)` | gzip encode. |
| `Uint8List decompress(Uint8List data, {int? maxOutputBytes})` | gzip decode. Throws `RpcStatusException` (`RpcStatus.resourceExhausted`) over the limit, `FormatException` on malformed input (bad header, CRC or size trailer). |

To undo a registration: `RpcGrpcCompression.unregister(RpcGrpcCompression.gzip)`.
On the VM this also removes the built-in gzip; it does not come back.

## Example

A responder and a caller over `pair()`, gzip on both sides, compression enabled
on the caller. The policy caps every message at 4 MiB, decompressed size
included.

```dart
import 'package:rpc_dart_compression/rpc_dart_compression.dart';

const docsService = 'Docs';

final class DocsResponder extends RpcResponderContract {
  DocsResponder() : super(docsService);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: _echo,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _echo(RpcString request, {RpcContext? context}) async =>
      request;
}

final class DocsCaller extends RpcCallerContract {
  DocsCaller(RpcCallerEndpoint endpoint) : super(docsService, endpoint);

  Future<RpcString> echo(RpcString request) =>
      callUnary<RpcString, RpcString>(
        methodName: 'echo',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      );
}

Future<void> main() async {
  // Once per process, before any endpoint exists. Both peers live in this
  // process here; across a network each side registers its own.
  RpcGzipCodec.register(level: RpcGzipCodec.fastestLevel);

  const policy = RpcSecurityPolicy(maxMessageLengthBytes: 4 * 1024 * 1024);
  final (client, server) = RpcChannelTransport.pair(policy: policy);

  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(DocsResponder())
    ..start();
  final caller = RpcCallerEndpoint(transport: client, compressionEnabled: true);

  final reply = await DocsCaller(caller).echo(RpcString('a' * 100000));
  print(reply.value.length);

  await caller.close();
  await responder.close();
}
```

## Limits on decompressed size

The core passes the receiving side's `maxMessageLengthBytes` to `decompress` as
`maxOutputBytes`. `maxDecompressedSize` can only lower that cap, never raise it.
A small compressed frame passes the frame-size check, so the decompressed limit
is what stops a payload that inflates past the policy.

```dart
void decompressionLimit() {
  const codec = RpcGzipCodec(maxDecompressedSize: 1024 * 1024);
  final packed = codec.compress(Uint8List(2 * 1024 * 1024));
  try {
    codec.decompress(packed, maxOutputBytes: 64 * 1024);
  } on RpcStatusException catch (e) {
    // e.statusCode == RpcStatus.resourceExhausted
    print(e.statusCode);
  }
}
```

The check reads the size gzip stores in its trailer first, so an honest
oversized payload is refused before any output is allocated. That trailer is
the size modulo 2^32, so a crafted payload can understate it:

| Target | Payload that understates its size |
| --- | --- |
| VM | inflation stops as soon as output passes the limit |
| dart2js, Wasm | the whole output is inflated, then refused |

On web nothing over the limit is ever returned, but refusing it costs the full
allocation and event-loop time first. Keep `maxMessageLengthBytes` (or
`maxDecompressedSize`) as low as your real messages allow on web peers that
accept data from untrusted senders.

## Pitfalls

- Registering on one side only. A caller that declares `gzip` to a responder
  without it gets `UNIMPLEMENTED` on every call. On the VM both sides have the
  built-in gzip anyway; on web both need `RpcGzipCodec.register()`.
- Forgetting `compressionEnabled: true` on the caller. Then neither requests
  nor responses are compressed, whatever is registered.
- Expecting every message to be compressed. A message is sent compressed only
  if that makes it smaller, so small or incompressible ones go out plain.
- Testing over `memoryPair()` and seeing no effect. Compression is skipped on
  zero-copy transports.
- Raising `maxDecompressedSize` above the policy and expecting larger messages
  to pass. The smaller limit wins; raise `maxMessageLengthBytes` on the
  transport instead.
- Catching only `RpcStatusException` around a direct `decompress` call.
  Malformed input throws `FormatException`; over the wire the core reports it
  as `INTERNAL`.

The full reference is the `rpc_dart_compression` README.
