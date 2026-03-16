// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:archive/archive.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Cross-platform gzip [RpcCompressionCodec] backed by [package:archive].
///
/// Works on all platforms: native, web, JS, Wasm.
///
/// Register once at application startup via [RpcGzipCodec.register]:
/// ```dart
/// RpcGzipCodec.register();
/// ```
final class RpcGzipCodec implements RpcCompressionCodec {
  const RpcGzipCodec();

  /// Registers this codec with [RpcGrpcCompression] for the `gzip` encoding.
  ///
  /// Replaces any previously registered gzip codec (including the built-in
  /// dart:io one on native platforms).
  static void register() {
    RpcGrpcCompression.register(RpcGrpcCompression.gzip, const RpcGzipCodec());
  }

  @override
  Uint8List compress(Uint8List data) {
    final result = GZipEncoder().encode(data);
    if (result == null) throw StateError('GZipEncoder returned null');
    return Uint8List.fromList(result);
  }

  @override
  Uint8List decompress(Uint8List data) {
    return Uint8List.fromList(GZipDecoder().decodeBytes(data));
  }
}
