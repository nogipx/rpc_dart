// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io' show gzip;
import 'dart:typed_data';

import 'errors.dart';
import 'protocol.dart' show RpcStatus;

/// Returns true on native platforms where dart:io gzip is available.
bool get rpcGzipSupported => true;

/// Compresses [data] using dart:io gzip.
Uint8List rpcGzipCompress(Uint8List data) => _asBytes(gzip.encode(data));

/// [bytes] as a [Uint8List], copying only when the codec did not already
/// return one.
Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

/// Decompresses [data] using dart:io gzip.
///
/// When [maxOutputBytes] is non-null, decoding is performed in a chunked
/// manner and aborts as soon as the accumulated output would exceed the
/// limit. This bounds memory against decompression bombs: a tiny gzip payload
/// that expands to gigabytes is rejected before being materialized in full.
/// Throws a RESOURCE_EXHAUSTED [RpcStatusException] when the limit is exceeded,
/// and [FormatException] when the input is not valid gzip.
Uint8List rpcGzipDecompress(Uint8List data, {int? maxOutputBytes}) {
  if (maxOutputBytes == null) {
    return _asBytes(gzip.decode(data));
  }

  final builder = BytesBuilder(copy: false);
  // The decoder hands its output to the sink piece by piece while it works
  // through one `add`, so the sink's throw stops it there: the input need not
  // be fed in chunks. Delivery is synchronous for in-memory input, so no async
  // hop is needed at the parser call site.
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
      throw RpcStatusException(
        RpcStatus.resourceExhausted,
        'Decompressed gzip payload exceeds limit: '
        '${_builder.length} bytes (max: $_maxOutputBytes)',
      );
    }
  }

  @override
  void close() {}
}
