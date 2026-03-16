// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'compression_gzip_stub.dart'
    if (dart.library.io) 'compression_gzip_io.dart' as gzip_impl;

/// Interface for a pluggable compression codec.
///
/// Implement this class and register it with [RpcGrpcCompression.register]
/// to add compression support for a given encoding on any platform:
///
/// ```dart
/// RpcGrpcCompression.register('gzip', MyGzipCodec());
/// ```
abstract class RpcCompressionCodec {
  const RpcCompressionCodec();

  Uint8List compress(Uint8List data);
  Uint8List decompress(Uint8List data);
}

/// Built-in codec backed by the dart:io gzip stub/io conditional import.
final class _BuiltinGzipCodec implements RpcCompressionCodec {
  const _BuiltinGzipCodec();

  @override
  Uint8List compress(Uint8List data) => gzip_impl.rpcGzipCompress(data);

  @override
  Uint8List decompress(Uint8List data) => gzip_impl.rpcGzipDecompress(data);
}

/// Minimal gRPC message compression helpers.
///
/// Supports `identity` everywhere. Additional encodings (e.g. `gzip`) are
/// provided either automatically on native platforms (via `dart:io`) or by
/// registering an external [RpcCompressionCodec]:
///
/// ```dart
/// // e.g. in a web app using package:archive
/// RpcGrpcCompression.register('gzip', ArchiveGzipCodec());
/// ```
abstract final class RpcGrpcCompression {
  static const String identity = 'identity';
  static const String gzip = 'gzip';

  /// Codec registry. Populated at startup with the dart:io gzip codec on
  /// native platforms; external codecs can be added via [register].
  static final Map<String, RpcCompressionCodec> _codecs = _initDefaults();

  static Map<String, RpcCompressionCodec> _initDefaults() {
    final map = <String, RpcCompressionCodec>{};
    if (gzip_impl.rpcGzipSupported) {
      map[gzip] = const _BuiltinGzipCodec();
    }
    return map;
  }

  /// Registers [codec] for [encoding], replacing any existing one.
  ///
  /// Call this once at application startup before any RPC calls are made.
  /// On web, register a gzip codec backed by `package:archive` (or similar)
  /// to enable gzip compression:
  ///
  /// ```dart
  /// RpcGrpcCompression.register('gzip', ArchiveGzipCodec());
  /// ```
  static void register(String encoding, RpcCompressionCodec codec) {
    _codecs[encoding] = codec;
  }

  /// Removes the codec registered for [encoding].
  static void unregister(String encoding) {
    _codecs.remove(encoding);
  }

  static bool isSupported(String encoding) {
    if (encoding == identity) return true;
    return _codecs.containsKey(encoding);
  }

  static Uint8List compress(Uint8List data, {required String encoding}) {
    if (encoding == identity) return data;
    final codec = _codecs[encoding];
    if (codec == null) {
      throw UnsupportedError('Unsupported grpc-encoding: $encoding');
    }
    return codec.compress(data);
  }

  static Uint8List decompress(Uint8List data, {required String encoding}) {
    if (encoding == identity) return data;
    final codec = _codecs[encoding];
    if (codec == null) {
      throw UnsupportedError('Unsupported grpc-encoding: $encoding');
    }
    return codec.decompress(data);
  }

  /// Picks the best encoding the peer advertised it can decompress.
  ///
  /// [acceptEncoding] is the raw `grpc-accept-encoding` header value
  /// (comma-separated list, e.g. `"gzip, identity"`).
  /// Returns the first supported non-identity encoding, or `null` for identity.
  static String? selectResponseEncoding(String? acceptEncoding) {
    if (acceptEncoding == null) return null;
    for (final enc in acceptEncoding.split(',').map((e) => e.trim())) {
      if (enc != identity && isSupported(enc)) {
        return enc;
      }
    }
    return null;
  }

  static List<String> supportedEncodings() {
    return [identity, ..._codecs.keys];
  }
}
