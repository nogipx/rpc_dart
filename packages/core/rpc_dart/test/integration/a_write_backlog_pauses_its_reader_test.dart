// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWriteBacklog: past its bound the reader pauses, at half it resumes, and
// a write that ends, failed or not, resumes it too.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// Takes nothing until [take] is called, as a socket whose kernel buffer is
/// full; [fail] ends the write with an error.
final class _HeldSink implements StreamConsumer<List<int>> {
  late final StreamSubscription<List<int>> _sub;
  final Completer<void> _done = Completer<void>();
  int _allowed = 0;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _sub = stream.listen(
      (_) {
        if (--_allowed == 0) _sub.pause();
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
    )..pause();
    return _done.future;
  }

  /// Lets [chunks] chunks through.
  Future<void> take(int chunks) async {
    _allowed = chunks;
    _sub.resume();
    await Future<void>.delayed(Duration.zero);
  }

  void fail() {
    unawaited(_sub.cancel());
    _done.completeError(StateError('write failed'));
  }

  @override
  Future<void> close() async {}
}

void main() {
  late StreamController<int> peer;
  late StreamSubscription<int> reader;

  setUp(() {
    peer = StreamController<int>();
    reader = peer.stream.listen((_) {});
  });

  tearDown(() async {
    await reader.cancel();
  });

  test('past the bound the reader pauses, at half it resumes', () async {
    final backlog = RpcWriteBacklog(maxUnsentBytes: 100);
    backlog.attachReader(reader);
    final sink = _HeldSink();
    final out = StreamController<List<int>>(sync: true);
    unawaited(backlog.pipe(out.stream, sink));

    for (var i = 0; i < 4; i++) {
      out.add(List<int>.filled(30, 0));
    }
    expect(reader.isPaused, isTrue, reason: '120 bytes unsent, bound 100');

    await sink.take(2);
    expect(reader.isPaused, isTrue, reason: '60 bytes unsent, half is 50');

    await sink.take(1);
    expect(reader.isPaused, isFalse, reason: '30 bytes unsent');
  });

  test('a failed write resumes the reader', () async {
    final backlog = RpcWriteBacklog(maxUnsentBytes: 10);
    backlog.attachReader(reader);
    final sink = _HeldSink();
    final out = StreamController<List<int>>(sync: true);
    final writing = backlog.pipe(out.stream, sink);
    out.add(List<int>.filled(20, 0));
    expect(reader.isPaused, isTrue);

    sink.fail();
    await expectLater(writing, throwsStateError);
    expect(reader.isPaused, isFalse);
  });

  test('a reader attached while over is paused at once', () async {
    final backlog = RpcWriteBacklog(maxUnsentBytes: 10);
    final out = StreamController<List<int>>(sync: true);
    unawaited(backlog.pipe(out.stream, _HeldSink()));
    out.add(List<int>.filled(20, 0));

    backlog.attachReader(reader);
    expect(reader.isPaused, isTrue);
  });

  test('without a bound the reader never pauses', () async {
    final backlog = RpcWriteBacklog(maxUnsentBytes: null);
    backlog.attachReader(reader);
    final out = StreamController<List<int>>(sync: true);
    unawaited(backlog.pipe(out.stream, _HeldSink()));
    out.add(List<int>.filled(1 << 20, 0));
    expect(reader.isPaused, isFalse);
  });
}
