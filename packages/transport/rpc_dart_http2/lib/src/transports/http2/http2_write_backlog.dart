// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

/// Stops reading a peer while too much of what was written to it is unsent.
///
/// package:http2 never pauses its frame reader, and an answer that is HEADERS
/// alone is outside flow control, so a peer that reads nothing and keeps
/// opening calls is answered into a queue without end. [reads] wraps the
/// socket's incoming bytes and [writes] its outgoing ones: past
/// [maxUnsentBytes] unsent, reading stops until the backlog has halved.
///
/// For a server only: if both ends paused, each would wait for the other to
/// read.
final class Http2WriteBacklog {
  /// Wraps [outgoing], which this then writes to through `addStream`.
  Http2WriteBacklog(this._outgoing, {required this.maxUnsentBytes});

  /// Unsent bytes past which reading stops.
  final int maxUnsentBytes;

  final StreamSink<List<int>> _outgoing;

  /// Synchronous, so a write the kernel can take now is not held a microtask.
  /// dart:io pauses the stream it writes from while the kernel is full, so
  /// what is still queued sits here, where [_unsent] counts it.
  final StreamController<List<int>> _out = StreamController<List<int>>(
    sync: true,
  );
  Future<void>? _writing;
  int _unsent = 0;
  bool _over = false;
  StreamSubscription<List<int>>? _reader;

  /// [incoming], paused while the backlog is over the limit.
  Stream<List<int>> reads(Stream<List<int>> incoming) {
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        final reader = incoming.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        _reader = reader;
        if (_over) reader.pause();
      },
      onPause: () => _reader?.pause(),
      onResume: () => _reader?.resume(),
      onCancel: () => _reader?.cancel(),
    );
    return controller.stream;
  }

  /// The sink package:http2 writes its frames to.
  ///
  /// It never pauses package:http2's writer: a writer resumed after its
  /// connection closed writes into a closed sink and throws.
  late final StreamSink<List<int>> writes = _BacklogSink(this);

  Future<void> _start() =>
      _writing ??= _outgoing.addStream(_out.stream.map(_taken));

  void _write(List<int> data) {
    if (_out.isClosed) return;
    _unsent += data.length;
    _out.add(data);
    if (!_over && _unsent > maxUnsentBytes) {
      _over = true;
      _reader?.pause();
    }
  }

  /// [_outgoing] has taken [data].
  List<int> _taken(List<int> data) {
    _unsent -= data.length;
    if (_over && _unsent <= maxUnsentBytes ~/ 2) {
      _over = false;
      _reader?.resume();
    }
    return data;
  }
}

final class _BacklogSink implements StreamSink<List<int>> {
  _BacklogSink(this._backlog);

  final Http2WriteBacklog _backlog;

  @override
  void add(List<int> data) {
    _backlog._start().ignore();
    _backlog._write(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final done = Completer<void>();
    late final StreamSubscription<List<int>> source;
    // A failed write ends the source too, as dart:io's own addStream does.
    _backlog._start().then(
      (_) {},
      onError: (Object e, StackTrace st) {
        unawaited(source.cancel());
        if (!done.isCompleted) done.completeError(e, st);
      },
    );
    source = stream.listen(
      _backlog._write,
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    return done.future;
  }

  @override
  Future<void> close() async {
    final backlog = _backlog;
    final writing = backlog._start();
    await backlog._out.close();
    await writing;
    await backlog._outgoing.close();
  }

  @override
  Future<void> get done => _backlog._outgoing.done;
}
