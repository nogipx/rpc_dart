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
///
/// The compression [level] (0..9) and a [maxDecompressedSize] guard against
/// decompression bombs can be configured:
/// ```dart
/// RpcGzipCodec.register(level: 9); // smallest output, slowest
/// ```
final class RpcGzipCodec implements RpcCompressionCodec {
  /// Compression level passed to the gzip encoder, in the range 0..9
  /// (`0` = store/no compression, `1` = fastest, `9` = smallest output).
  ///
  /// Defaults to `6`, matching the archive package default
  /// ([defaultLevel]); existing callers see unchanged behaviour.
  final int level;

  /// Maximum allowed decompressed size in bytes. Decompression throws a
  /// [FormatException] before allocating if the gzip ISIZE trailer declares a
  /// larger output, guarding against decompression bombs.
  ///
  /// Defaults to unlimited ([_unlimited]). The check is cheap because gzip
  /// already stores the uncompressed size (mod 2^32) in its trailer, so no
  /// extra work is done for payloads within the limit.
  ///
  /// Note: ISIZE is only the size modulo 2^32, so this guard is exact only for
  /// outputs below 4 GiB; for larger declared sizes set the limit accordingly.
  final int maxDecompressedSize;

  /// Default compression level (archive / zlib default).
  static const int defaultLevel = 6;

  /// Fastest compression level.
  static const int fastestLevel = 1;

  /// Smallest-output compression level.
  static const int bestLevel = 9;

  /// Sentinel for "no decompressed-size limit".
  static const int _unlimited = -1;

  const RpcGzipCodec({
    this.level = defaultLevel,
    this.maxDecompressedSize = _unlimited,
  });

  /// Registers a [RpcGzipCodec] with [RpcGrpcCompression] for the `gzip`
  /// encoding.
  ///
  /// Replaces any previously registered gzip codec (including the built-in
  /// dart:io one on native platforms). [level] and [maxDecompressedSize] are
  /// forwarded to the codec constructor.
  static void register({
    int level = defaultLevel,
    int maxDecompressedSize = _unlimited,
  }) {
    RpcGrpcCompression.register(
      RpcGrpcCompression.gzip,
      RpcGzipCodec(level: level, maxDecompressedSize: maxDecompressedSize),
    );
  }

  @override
  Uint8List compress(Uint8List data) {
    // GZipEncoder.encodeBytes returns a Uint8List on every platform (native
    // GZipCodec on the VM, OutputMemoryStream.getBytes on web), so no extra
    // Uint8List.fromList copy is needed here.
    //
    // The archive 4.x streaming API (encodeStream + Output/InputMemoryStream)
    // does not reduce peak memory for this Uint8List -> Uint8List interface:
    // the output is still accumulated into a single contiguous OutputMemory
    // Stream buffer before getBytes(). It would only add a no-op indirection,
    // so the whole-buffer encode is kept.
    return GZipEncoder().encodeBytes(data, level: level);
  }

  @override
  Uint8List decompress(Uint8List data) {
    // The archive web decoder has its signature checks commented out and the
    // VM decoder defaults to verify:false, so corrupted / non-gzip / truncated
    // input can be silently accepted (garbage or empty) and behaviour diverges
    // between VM and web. Guard explicitly so all platforms behave the same.
    _validateGzipHeader(data);

    // Decompression-bomb guard: gzip stores the uncompressed size (mod 2^32) in
    // the ISIZE trailer, so we can reject oversized declared output before
    // allocating anything. Cheap and never triggers for in-limit payloads.
    if (maxDecompressedSize != _unlimited) {
      final n = data.length;
      final declaredSize = data[n - 4] |
          (data[n - 3] << 8) |
          (data[n - 2] << 16) |
          (data[n - 1] << 24);
      if (declaredSize > maxDecompressedSize) {
        throw FormatException(
          'Invalid gzip data: declared size $declaredSize exceeds '
          'maxDecompressedSize $maxDecompressedSize',
        );
      }
    }

    final List<int> result;
    try {
      // verify:true enforces the CRC32 + ISIZE trailer check on the VM.
      // decodeBytes already returns a Uint8List, but the trailer re-check below
      // works on any List<int>, so keep the declared type loose.
      result = GZipDecoder().decodeBytes(data, verify: true);
    } catch (e) {
      throw FormatException('Invalid gzip data: $e');
    }

    // The archive web decoder has its CRC/length verification commented out, so
    // verify:true is a no-op there: corrupted or truncated payloads decode to
    // garbage without throwing. Re-check the gzip trailer ourselves so the
    // behaviour matches the VM on every platform.
    _verifyTrailer(data, result);

    // decodeBytes returns a Uint8List on every platform, so avoid the extra
    // Uint8List.fromList copy. Cast defensively in case a future archive
    // version changes the concrete type.
    return result is Uint8List ? result : Uint8List.fromList(result);
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
