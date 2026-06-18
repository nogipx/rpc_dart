<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Compression

The `rpc_dart_compression` package provides a cross-platform gzip codec for `rpc_dart`. It replaces the built-in `dart:io` gzip implementation, which is native-only, with one backed by `package:archive` that works on all platforms — native, web, JS, and Wasm.

---

## Setup

```yaml
dependencies:
  rpc_dart_compression: ^0.1.0
```

Call `RpcGzipCodec.register()` once at application startup, before creating any endpoints:

```dart
import 'package:rpc_dart_compression/rpc_dart_compression.dart';

void main() {
  RpcGzipCodec.register();
  // ...
}
```

That's it. Registration adds the codec to the `RpcGrpcCompression` registry under the `'gzip'` encoding key. Any endpoint with compression enabled will use it automatically.

---

## How It Works

`rpc_dart` uses a compression registry (`RpcGrpcCompression`) that maps encoding names to codec implementations. When a message is sent over a transport that has compression enabled, the framework looks up the codec by name, compresses the payload, and sets the compression flag in the 5-byte gRPC message header.

`RpcGzipCodec.register()` is equivalent to:

```dart
RpcGrpcCompression.register(RpcGrpcCompression.gzip, const RpcGzipCodec());
```

Registering a second time replaces the previous codec for that encoding — so calling `register()` on web overrides the native `dart:io` codec if it was registered earlier.

---

## Enabling Compression on an Endpoint

Compression is controlled on the `RpcCallerEndpoint`:

```dart
final callerEndpoint = RpcCallerEndpoint(
  transport: transport,
  compressionEnabled: true,
);
```

!!! note
    Compression is automatically disabled for `RpcInMemoryTransport` regardless of the flag — zero-copy transfer makes it pointless.

---

## Custom Codecs

You can register additional compression codecs by implementing `RpcCompressionCodec`:

```dart
class MyBrotliCodec implements RpcCompressionCodec {
  @override
  Uint8List compress(Uint8List data) { ... }

  @override
  Uint8List decompress(Uint8List data) { ... }
}

RpcGrpcCompression.register('br', const MyBrotliCodec());
```