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
///
/// dart:io hands body data as views of its socket read buffer, and a peer can
/// fill the rest of that buffer with bytes no limit counts (a chunk
/// extension). Views are kept only while the buffers they hold stay within
/// twice the bytes collected; past that a chunk is copied.
final class BodyAccumulator {
  /// Chunks shorter than this are copied together.
  static const int smallChunk = 4096;

  /// The copied small chunks are handed on as one chunk at this size.
  static const int flushAt = 64 * 1024;

  final BytesBuilder _whole = BytesBuilder(copy: false);
  final BytesBuilder _small = BytesBuilder();
  int _kept = 0;

  /// Bytes of the buffers the kept lists hold, each buffer counted once.
  int _held = 0;
  ByteBuffer? _lastBuffer;

  /// Bytes collected so far.
  int get length => _whole.length + _small.length;

  /// Lists held, one per large chunk and one per flush of small ones: what
  /// the heap pays for besides the bytes.
  int get keptLists => _kept + (_small.isNotEmpty ? 1 : 0);

  /// Bytes of memory the collected body holds, which can exceed [length]
  /// where a kept chunk is a view into a larger buffer.
  int get heldBytes => _held + _small.length;

  /// Adds [chunk].
  void add(List<int> chunk) {
    if (chunk.length >= smallChunk && _mayKeep(chunk)) {
      _flushSmall();
      _whole.add(chunk);
      _kept++;
      return;
    }
    _small.add(chunk);
    if (_small.length >= flushAt) _flushSmall();
  }

  bool _mayKeep(List<int> chunk) {
    if (chunk is! Uint8List) {
      _held += chunk.length;
      return true;
    }
    final buffer = chunk.buffer;
    // The chunks of one read arrive together and share its buffer.
    if (buffer == _lastBuffer) return true;
    final held = _held + buffer.lengthInBytes;
    if (held > 2 * (length + chunk.length)) return false;
    _held = held;
    _lastBuffer = buffer;
    return true;
  }

  void _flushSmall() {
    if (_small.isEmpty) return;
    _held += _small.length;
    _whole.add(_small.takeBytes());
    _kept++;
  }

  /// The body, and the accumulator emptied.
  Uint8List takeBytes() {
    _flushSmall();
    _kept = 0;
    _held = 0;
    _lastBuffer = null;
    return _whole.takeBytes();
  }

  /// Drops what was collected.
  void clear() {
    _small.clear();
    _whole.clear();
    _kept = 0;
    _held = 0;
    _lastBuffer = null;
  }
}
