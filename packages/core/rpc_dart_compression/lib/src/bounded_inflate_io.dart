// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Thrown by [boundedInflate] the moment the output passes its limit.
class InflateLimitExceeded implements Exception {
  InflateLimitExceeded(this.limit);

  /// The cap that was passed.
  final int limit;

  @override
  String toString() => 'InflateLimitExceeded($limit)';
}

/// Inflates [data], aborting as soon as the output would exceed [limit].
///
/// `dart:io`'s gzip decoder is a converter, so it can be driven in chunks and
/// STOPPED: the sink below throws once the running total passes the cap, which
/// unwinds the conversion before the rest is produced.
///
/// This exists because `package:archive` cannot be stopped. Both of its paths
/// materialise the whole output first -- the VM one accumulates through a
/// `ChunkedConversionSink.withCallback` that only fires at close, and the web
/// one does `Inflate.stream(input).getBytes()` -- so a size check afterwards is
/// too late by definition.
///
/// Measured before this existed, a 4.0 MiB payload of compressed zeros whose
/// gzip ISIZE trailer wraps to 4096 (it is the size MOD 2^32, so a 4 GiB output
/// declares "4096" and slips past a pre-check), decompressed against a 16 MiB
/// limit:
///
///     RSS +1873 MiB, 17.5s, then FormatException  -- the guard fired last
///
/// A ~470x amplification per wire byte, reachable by anyone who can send a
/// gzip-encoded message to a peer that registered this codec.
Uint8List? boundedInflate(Uint8List data, int limit) {
  final builder = BytesBuilder(copy: false);
  var total = 0;

  final out = ByteConversionSink.withCallback((bytes) {
    builder.add(bytes);
  });

  // A sink that counts as it goes and refuses to grow past the cap.
  final counting = _CountingSink(out, limit, () => total, (n) => total = n);

  final inflater = gzip.decoder.startChunkedConversion(counting);
  try {
    // Fed in chunks so the decoder yields output incrementally; a single
    // `add` of the whole payload would still let it run to completion.
    const chunk = 64 * 1024;
    for (var offset = 0; offset < data.length; offset += chunk) {
      final end = offset + chunk < data.length ? offset + chunk : data.length;
      inflater.add(Uint8List.sublistView(data, offset, end));
    }
    inflater.close();
  } on InflateLimitExceeded {
    rethrow;
  }

  return builder.toBytes();
}

class _CountingSink extends ByteConversionSink {
  _CountingSink(this._target, this._limit, this._get, this._set);

  final ByteConversionSink _target;
  final int _limit;
  final int Function() _get;
  final void Function(int) _set;

  void _charge(int n) {
    final next = _get() + n;
    if (next > _limit) throw InflateLimitExceeded(_limit);
    _set(next);
  }

  @override
  void add(List<int> chunk) {
    _charge(chunk.length);
    _target.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    _charge(end - start);
    _target.addSlice(chunk, start, end, isLast);
  }

  @override
  void close() => _target.close();
}
