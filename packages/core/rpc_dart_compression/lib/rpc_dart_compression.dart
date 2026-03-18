// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Cross-platform compression codecs for rpc_dart.
///
/// Uses [package:archive](https://pub.dev/packages/archive) — compiles to all
/// platforms including JS and Wasm.
///
/// Usage:
/// ```dart
/// import 'package:rpc_dart_compression/rpc_dart_compression.dart';
///
/// void main() {
///   RpcGzipCodec.register(); // once, before any RPC calls
///   // ...
/// }
/// ```
library;

export 'src/gzip_codec.dart';
