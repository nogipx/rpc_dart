// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';

/// [RpcWriteBacklog] between package:http2 and a socket's two streams.
///
/// package:http2 never pauses its frame reader, and an answer that is HEADERS
/// alone is outside flow control, so a peer that reads nothing and keeps
/// opening calls is answered into a queue without end. [reads] wraps the
/// socket's incoming bytes and [writes] its outgoing ones.
final class Http2WriteBacklog {
  /// Wraps [outgoing], which this then writes to through `addStream`.
  Http2WriteBacklog(this._outgoing, {required int maxUnsentBytes})
    : _backlog = RpcWriteBacklog(maxUnsentBytes: maxUnsentBytes);

  final StreamSink<List<int>> _outgoing;
  final RpcWriteBacklog _backlog;

  /// Synchronous, so a write the kernel can take now is not held a microtask.
  final StreamController<List<int>> _out = StreamController<List<int>>(
    sync: true,
  );
  Future<void>? _writing;
  StreamSubscription<List<int>>? _reader;

  /// [incoming], paused while the backlog is over the limit.
  Stream<List<int>> reads(Stream<List<int>> incoming) {
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        final reader = _reader = incoming.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        _backlog.attachReader(reader);
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

  Future<void> _start() => _writing ??= _backlog.pipe(_out.stream, _outgoing);

  void _write(List<int> data) {
    if (!_out.isClosed) _out.add(data);
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
