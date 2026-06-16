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
    return Uint8List.fromList(result);
  }

  @override
  Uint8List decompress(Uint8List data) {
    // The archive web decoder has its signature checks commented out and the
    // VM decoder defaults to verify:false, so corrupted / non-gzip / truncated
    // input can be silently accepted (garbage or empty) and behaviour diverges
    // between VM and web. Guard explicitly so all platforms behave the same.
    _validateGzipHeader(data);

    final List<int> result;
    try {
      // verify:true enforces the CRC32 + ISIZE trailer check on the VM.
      result = GZipDecoder().decodeBytes(data, verify: true);
    } catch (e) {
      throw FormatException('Invalid gzip data: $e');
    }

    // The archive web decoder has its CRC/length verification commented out, so
    // verify:true is a no-op there: corrupted or truncated payloads decode to
    // garbage without throwing. Re-check the gzip trailer ourselves so the
    // behaviour matches the VM on every platform.
    _verifyTrailer(data, result);

    return Uint8List.fromList(result);
  }

  /// Validates the gzip trailer (RFC 1952): the last 8 bytes are CRC32 and
  /// ISIZE (uncompressed size mod 2^32), both little-endian. Throws a
  /// [FormatException] if either does not match the decoded output.
  static void _verifyTrailer(Uint8List data, List<int> output) {
    final n = data.length;
    final expectedCrc = data[n - 8] |
        (data[n - 7] << 8) |
        (data[n - 6] << 16) |
        (data[n - 5] << 24);
    final expectedSize = data[n - 4] |
        (data[n - 3] << 8) |
        (data[n - 2] << 16) |
        (data[n - 1] << 24);

    if ((output.length & 0xffffffff) != (expectedSize & 0xffffffff)) {
      throw FormatException(
        'Invalid gzip data: size mismatch '
        '(expected $expectedSize, got ${output.length})',
      );
    }
    final actualCrc = getCrc32(output) & 0xffffffff;
    if (actualCrc != (expectedCrc & 0xffffffff)) {
      throw const FormatException('Invalid gzip data: CRC32 mismatch');
    }
  }

  /// Validates the gzip header (magic bytes + compression method) so malformed
  /// or non-gzip input is rejected consistently on VM and web.
  ///
  /// gzip header (RFC 1952): byte 0 = 0x1f, byte 1 = 0x8b, byte 2 = CM (8 =
  /// DEFLATE, the only method gzip defines).
  static void _validateGzipHeader(Uint8List data) {
    if (data.length < 18) {
      // Minimum valid gzip: 10-byte header + 8-byte trailer.
      throw const FormatException('Invalid gzip data: too short');
    }
    if (data[0] != 0x1f || data[1] != 0x8b) {
      throw const FormatException(
        'Invalid gzip data: bad magic (expected 0x1f 0x8b)',
      );
    }
    if (data[2] != 0x08) {
      throw FormatException(
        'Invalid gzip data: unsupported compression method ${data[2]}',
      );
    }
  }
}
