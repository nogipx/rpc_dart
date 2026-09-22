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

## Decompression limits

`maxDecompressedSize` bounds what a compressed message may inflate to:

```dart
RpcGzipCodec.register(maxDecompressedSize: 16 * 1024 * 1024);
```

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
time first. Against a 16 MiB limit, ~65 KiB of wire inflating to 64 MiB is
refused about three orders of magnitude slower on dart2js than on the VM.

This is not configurable, and lowering `maxDecompressedSize` does not remove it —
it only changes the size of what a hostile peer can make you spend. Treat the
limit as a bound on what you accept, and on web assume refusing is not free.
`test/audit/isize_understates_on_web_test.dart` carries the current figures.
