// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'compression_gzip_stub.dart'
    if (dart.library.io) 'compression_gzip_io.dart' as gzip_impl;

/// Minimal gRPC message compression helpers.
///
/// Supports `identity` everywhere and `gzip` on platforms with `dart:io`.
abstract final class RpcGrpcCompression {
  static const String identity = 'identity';
  static const String gzip = 'gzip';

  static bool isSupported(String encoding) {
    switch (encoding) {
      case identity:
        return true;
      case gzip:
        return gzip_impl.rpcGzipSupported;
      default:
        return false;
    }
  }

  static Uint8List compress(Uint8List data, {required String encoding}) {
    switch (encoding) {
      case identity:
        return data;
      case gzip:
        return gzip_impl.rpcGzipCompress(data);
      default:
        throw UnsupportedError('Unsupported grpc-encoding: $encoding');
    }
  }

  static Uint8List decompress(Uint8List data, {required String encoding}) {
    switch (encoding) {
      case identity:
        return data;
      case gzip:
        return gzip_impl.rpcGzipDecompress(data);
      default:
        throw UnsupportedError('Unsupported grpc-encoding: $encoding');
    }
  }

  static List<String> supportedEncodings() {
    final encodings = <String>[identity];
    if (gzip_impl.rpcGzipSupported) {
      encodings.add(gzip);
    }
    return encodings;
  }
}
