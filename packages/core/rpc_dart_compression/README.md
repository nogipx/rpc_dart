<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_compression

Cross-platform compression codecs for `rpc_dart`.

`rpc_dart` negotiates per-message compression through the gRPC
`grpc-encoding` / `grpc-accept-encoding` headers, but the built-in gzip is
VM-only (`dart:io`). On dart2js and Wasm a compressed payload therefore fails
with "Unsupported grpc-encoding: gzip". This package fills that gap with a gzip
codec that works on every target.

- `RpcGzipCodec` — gzip implemented over the `archive` package, no `dart:io`.
- `RpcGzipCodec.register()` — installs it into the core compression registry.

## Usage

```dart
import 'package:rpc_dart_compression/rpc_dart_compression.dart';

void main() {
  // Once, before creating endpoints.
  RpcGzipCodec.register();
}
```

After registration, `grpc-encoding: gzip` round-trips on VM, dart2js and Wasm
alike.
