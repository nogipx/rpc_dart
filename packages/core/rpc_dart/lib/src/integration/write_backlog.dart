// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

/// Stops reading a peer while too much of what was written to it is unsent.
///
/// A server answers every call, and part of an answer (headers, trailers) is
/// outside flow control. A peer that reads nothing and keeps starting calls
/// is therefore answered into a write queue without end, unless the server
/// stops reading it. Past [maxUnsentBytes] unsent, the reader given to
/// [attachReader] is paused until half has gone out.
///
/// The reader also resumes when the write ends, failed or not: a reader left
/// paused holds back the done event of a socket that failed or was destroyed,
/// and the connection never ends.
///
/// For a server only: if both ends paused, each would wait for the other to
/// read.
final class RpcWriteBacklog {
  /// A backlog that pauses past [maxUnsentBytes]; null never pauses.
  RpcWriteBacklog({required this.maxUnsentBytes});

  /// The bound every rpc_dart server uses.
  static const int defaultServerMax = 1024 * 1024;

  /// Unsent bytes past which reading stops, or null.
  final int? maxUnsentBytes;

  int _unsent = 0;
  bool _over = false;
  StreamSubscription<Object?>? _reader;

  /// The reader to pause. Paused at once if the backlog is already over.
  void attachReader(StreamSubscription<Object?> reader) {
    _reader = reader;
    if (_over) reader.pause();
  }

  /// Writes [source] to [sink] through `addStream`, counting what [sink] has
  /// not taken yet.
  ///
  /// [source] is never paused: dart:io pauses the stream it writes from while
  /// the kernel is full, and what it holds above a paused stream is
  /// uncounted, so every byte has to land in a queue this counts.
  Future<void> pipe(Stream<List<int>> source, StreamConsumer<List<int>> sink) {
    if (maxUnsentBytes == null) return sink.addStream(source);
    // Synchronous, so a write the kernel can take now is not held a microtask.
    final queue = StreamController<List<int>>(sync: true);
    late final StreamSubscription<List<int>> feed;
    final writing = sink.addStream(queue.stream.map(_taken)).whenComplete(() {
      unawaited(feed.cancel());
      _release();
    });
    feed = source.listen(
      (data) {
        _unsent += data.length;
        queue.add(data);
        if (!_over && _unsent > maxUnsentBytes!) {
          _over = true;
          _reader?.pause();
        }
      },
      onError: queue.addError,
      onDone: queue.close,
      cancelOnError: true,
    );
    return writing;
  }

  /// The sink has taken [data].
  List<int> _taken(List<int> data) {
    _unsent -= data.length;
    if (_unsent <= maxUnsentBytes! ~/ 2) _release();
    return data;
  }

  void _release() {
    if (!_over) return;
    _over = false;
    _reader?.resume();
  }
}
