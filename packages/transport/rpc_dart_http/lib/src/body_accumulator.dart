// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Collects an HTTP body whose chunk sizes the PEER chooses.
///
/// A `BytesBuilder(copy: false)` keeps every chunk as its own list, with a
/// fixed cost whatever its length, so a body sent as one-byte chunks held many
/// times its size in heap under a ceiling that counts bytes. Small chunks are
/// therefore copied into one buffer, and only large ones are kept as they
/// came, which is the copy `copy: false` exists to avoid.
final class BodyAccumulator {
  /// Chunks shorter than this are copied together.
  static const int smallChunk = 4096;

  /// The copied small chunks are handed on as one chunk at this size.
  static const int flushAt = 64 * 1024;

  final BytesBuilder _whole = BytesBuilder(copy: false);
  final BytesBuilder _small = BytesBuilder();
  int _kept = 0;

  /// Bytes collected so far.
  int get length => _whole.length + _small.length;

  /// Lists held, one per large chunk and one per flush of small ones: what
  /// the heap pays for besides the bytes.
  int get keptLists => _kept + (_small.isNotEmpty ? 1 : 0);

  /// Adds [chunk].
  void add(List<int> chunk) {
    if (chunk.length >= smallChunk) {
      _flushSmall();
      _whole.add(chunk);
      _kept++;
      return;
    }
    _small.add(chunk);
    if (_small.length >= flushAt) _flushSmall();
  }

  void _flushSmall() {
    if (_small.isEmpty) return;
    _whole.add(_small.takeBytes());
    _kept++;
  }

  /// The body, and the accumulator emptied.
  Uint8List takeBytes() {
    _flushSmall();
    _kept = 0;
    return _whole.takeBytes();
  }

  /// Drops what was collected.
  void clear() {
    _small.clear();
    _whole.clear();
    _kept = 0;
  }
}
