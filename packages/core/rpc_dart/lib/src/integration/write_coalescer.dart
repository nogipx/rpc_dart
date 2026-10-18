// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

/// Joins the frames written in one event-loop turn into one write.
///
/// For a channel where each write has a fixed cost: a WebSocket message, a
/// socket write, a message across a platform bridge. A unary call writes its
/// headers, payload, trailer and flow-control grants as separate frames, each
/// a few bytes long, and a channel that writes each on its own pays that cost
/// several times per call. Byte streams and the frame decoder take several
/// frames per chunk, so joining them changes nothing on the wire but the
/// write count.
///
/// The writes are flushed on a zero-duration timer, after the microtasks that
/// produced them: a sender awaits between its frames, so a microtask flush
/// would run before the next frame of the same call arrives.
///
/// A frame of [directBytes] or more is written on its own, after what is
/// pending, without a copy. A batch is flushed once it reaches [maxBytes].
final class RpcWriteCoalescer {
  /// Creates a coalescer that hands each joined write to [write].
  RpcWriteCoalescer(
    this._write, {
    this.maxBytes = 64 * 1024,
    this.directBytes = 16 * 1024,
  });

  final void Function(Uint8List data) _write;

  /// A batch this large is written at once.
  final int maxBytes;

  /// A frame this large is not copied into a batch.
  final int directBytes;

  final List<Uint8List> _pending = [];
  int _pendingBytes = 0;
  Timer? _timer;

  /// Queues [data] for the next flush, keeping the order of [add] calls.
  void add(Uint8List data) {
    if (data.length >= directBytes) {
      flush();
      _write(data);
      return;
    }
    _pending.add(data);
    _pendingBytes += data.length;
    if (_pendingBytes >= maxBytes) {
      flush();
      return;
    }
    _timer ??= Timer(Duration.zero, flush);
  }

  /// Writes what is pending now. A channel calls this before it closes, so a
  /// trailer queued just before the close still goes out.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    // Taken before the write: a write that fails may close its channel, and
    // the close flushes again.
    final Uint8List out;
    if (_pending.length == 1) {
      out = _pending.first;
    } else {
      out = Uint8List(_pendingBytes);
      var o = 0;
      for (final p in _pending) {
        out.setRange(o, o + p.length, p);
        o += p.length;
      }
    }
    _pending.clear();
    _pendingBytes = 0;
    _write(out);
  }

  /// Drops what is pending, for a channel that is gone.
  void discard() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _pendingBytes = 0;
  }
}
