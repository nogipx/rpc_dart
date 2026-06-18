// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io' show gzip;
import 'dart:typed_data';

/// Returns true on native platforms where dart:io gzip is available.
bool get rpcGzipSupported => true;

/// Compresses [data] using dart:io gzip.
Uint8List rpcGzipCompress(Uint8List data) =>
    Uint8List.fromList(gzip.encode(data));

/// Decompresses [data] using dart:io gzip.
///
/// When [maxOutputBytes] is non-null, decoding is performed in a chunked
/// manner and aborts as soon as the accumulated output would exceed the
/// limit. This bounds memory against decompression bombs: a tiny gzip payload
/// that expands to gigabytes is rejected before being materialized in full.
/// Throws [FormatException] when the limit is exceeded.
Uint8List rpcGzipDecompress(Uint8List data, {int? maxOutputBytes}) {
  if (maxOutputBytes == null) {
    return Uint8List.fromList(gzip.decode(data));
  }

  final builder = BytesBuilder(copy: false);
  // Drive the gzip decoder over the input chunk and observe output
  // incrementally via a chunked sink so we can abort before allocating the
  // full expansion. The sink delivers output synchronously for in-memory
  // input, so no async hop is needed at the parser call site.
  final sink = gzip.decoder.startChunkedConversion(
    _LimitedByteSink(builder, maxOutputBytes),
  );
  sink.add(data);
  sink.close();
  return builder.toBytes();
}

/// Sink that accumulates decoded bytes and throws once [_maxOutputBytes] is
/// exceeded, so a decompression bomb is stopped mid-stream.
class _LimitedByteSink implements Sink<List<int>> {
  final BytesBuilder _builder;
  final int _maxOutputBytes;

  _LimitedByteSink(this._builder, this._maxOutputBytes);

  @override
  void add(List<int> chunk) {
    _builder.add(chunk);
    if (_builder.length > _maxOutputBytes) {
      throw FormatException(
        'Decompressed gzip payload exceeds limit: '
        '${_builder.length} bytes (max: $_maxOutputBytes)',
      );
    }
  }

  @override
  void close() {}
}
