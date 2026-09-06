// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Thrown by [boundedInflate] the moment the output passes its limit.
///
/// Declared on both sides of the conditional import so the catch clause in
/// `gzip_codec.dart` compiles for web too; nothing throws it there, because
/// [boundedInflate] always returns null.
class InflateLimitExceeded implements Exception {
  InflateLimitExceeded(this.limit);

  /// The cap that was passed.
  final int limit;

  @override
  String toString() => 'InflateLimitExceeded($limit)';
}

/// Inflates [data], aborting as soon as the output would exceed [limit].
///
/// Returns `null` when the platform offers no incremental inflater, which means
/// the caller must fall back to a whole-buffer decode. On web that is the case:
/// `package:archive` materialises the entire output before handing it over
/// (`Inflate.stream(input).getBytes()`), so nothing can stop it part-way.
Uint8List? boundedInflate(Uint8List data, int limit) => null;
