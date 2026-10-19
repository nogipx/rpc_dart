// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math' show min;

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
final class RpcGzipCodec extends RpcCompressionCodec {
  /// Compression level passed to the gzip encoder, in the range 0..9
  /// (`0` = store/no compression, `1` = fastest, `9` = smallest output).
  ///
  /// Defaults to `6`, matching the archive package default
  /// ([defaultLevel]).
  final int level;

  /// Maximum allowed decompressed size in bytes. Decompression throws a
  /// RESOURCE_EXHAUSTED [RpcStatusException] before allocating if the gzip
  /// ISIZE trailer declares a larger output, guarding against decompression
  /// bombs. Malformed input throws [FormatException].
  ///
  /// Null, the default, sets no limit of its own. The check is cheap because gzip
  /// already stores the uncompressed size (mod 2^32) in its trailer, so no
  /// extra work is done for payloads within the limit.
  ///
  /// Note: ISIZE is only the size modulo 2^32, so this guard is exact only for
  /// outputs below 4 GiB; for larger declared sizes set the limit accordingly.
  ///
  /// **On web the limit is enforced AFTER the output is allocated, and that is
  /// not configurable.** A payload whose ISIZE understates it clears the
  /// pre-check; the VM then aborts the inflate at the limit, while dart2js and
  /// Wasm have no incremental inflater — `package:archive` materialises the
  /// whole output — so the check runs on the finished buffer. Nothing over the
  /// limit is ever returned, but on web the refusal costs the full allocation
  /// and the event-loop time first.
  ///
  /// So on web this is a bound on what you will accept, not a defence against
  /// what it costs to refuse.
  final int? maxDecompressedSize;

  /// Default compression level (archive / zlib default).
  static const int defaultLevel = 6;

  /// Fastest compression level.
  static const int fastestLevel = 1;

  /// Smallest-output compression level.
  static const int bestLevel = 9;

  const RpcGzipCodec({this.level = defaultLevel, this.maxDecompressedSize})
    : assert(
        level >= 0 && level <= 9,
        'gzip level must be in 0..9, got $level',
      );

  /// Registers a [RpcGzipCodec] with [RpcGrpcCompression] for the `gzip`
  /// encoding.
  ///
  /// Replaces any previously registered gzip codec (including the built-in
  /// dart:io one on native platforms). [level] and [maxDecompressedSize] are
  /// forwarded to the codec constructor.
  static void register({int level = defaultLevel, int? maxDecompressedSize}) {
    assert(level >= 0 && level <= 9, 'gzip level must be in 0..9, got $level');
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
    //
    // Defensively clamp the level at the encode site: the constructor `assert`
    // guards dev builds, but asserts are stripped in release / dart2js, and an
    // out-of-range level makes archive's deflate silently emit a gzip frame
    // with NO compressed payload (its range throw is commented out). Clamping
    // guarantees valid output everywhere.
    return GZipEncoder().encodeBytes(data, level: level.clamp(0, 9));
  }

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) {
    // The archive web decoder has its signature checks commented out and the
    // VM decoder defaults to verify:false, so corrupted / non-gzip / truncated
    // input can be silently accepted (garbage or empty) and behaviour diverges
    // between VM and web. Guard explicitly so all platforms behave the same.
    _validateGzipHeader(data);

    // Decompression-bomb guard: gzip stores the uncompressed size (mod 2^32) in
    // the ISIZE trailer, so we can reject oversized declared output before
    // allocating anything. Cheap and never triggers for in-limit payloads.
    // Effective limit = the tighter of the codec's configured cap and the
    // per-call hint from RpcCompressionCodec.decompress(maxOutputBytes:).
    final own = maxDecompressedSize;
    final effectiveLimit = maxOutputBytes == null
        ? own
        : own == null
        ? maxOutputBytes
        : min(own, maxOutputBytes);

    final declaredSize = _le32(data, data.length - 4);
    if (effectiveLimit != null) {
      if (declaredSize > effectiveLimit) {
        throw RpcStatusException(
          RpcStatus.resourceExhausted,
          'Gzip data declares $declaredSize bytes, over the limit '
          '$effectiveLimit',
        );
      }
    }

    // Native platforms use core's `dart:io` codec, which stops mid-stream at
    // the limit. That matters because the pre-check above trusts ISIZE, the
    // size MOD 2^32: a payload that inflates to k*2^32 + small declares "small"
    // and passes it. `package:archive` materialises the whole output before any
    // check can run, so on web, where [RpcGrpcCompression.platformGzip] is
    // null and there is no incremental inflater, the limit below fires only
    // after the output exists.
    final platform = RpcGrpcCompression.platformGzip;
    final List<int> result;
    try {
      result =
          platform?.decompress(data, maxOutputBytes: effectiveLimit) ??
          GZipDecoder().decodeBytes(data, verify: true);
    } on RpcStatusException {
      rethrow;
    } catch (e) {
      throw FormatException('Invalid gzip data: $e');
    }

    // ISIZE is only the size mod 2^32, so a crafted trailer can understate the
    // real output and slip past the pre-allocation guard above. The bytes are
    // now materialized, so enforce the limit on the actual length too --
    // BEFORE the trailer check, which such a payload also fails, so that an
    // oversized output reads as a size on the web as it does on the VM.
    if (effectiveLimit != null && result.length > effectiveLimit) {
      throw RpcStatusException(
        RpcStatus.resourceExhausted,
        'Decompressed gzip output is ${result.length} bytes, over the limit '
        '$effectiveLimit',
      );
    }

    // Needed on both paths. The archive web decoder skips its CRC and length
    // verification, and `dart:io` checks an intact trailer but returns what it
    // has for input cut off before or inside the trailer.
    _verifyTrailer(data, result, declaredSize);

    return result is Uint8List ? result : Uint8List.fromList(result);
  }

  /// The little-endian 32-bit value at [offset] of [data].
  static int _le32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);

  /// Validates the gzip trailer (RFC 1952): the last 8 bytes are CRC32 and
  /// ISIZE (uncompressed size mod 2^32, [expectedSize]), both little-endian.
  /// Throws a [FormatException] if either does not match the decoded output.
  static void _verifyTrailer(
    Uint8List data,
    List<int> output,
    int expectedSize,
  ) {
    final expectedCrc = _le32(data, data.length - 8);

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
    if (data.length < 20) {
      // Minimum valid gzip: 10-byte header, the 2-byte empty deflate stream
      // and the 8-byte trailer.
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
