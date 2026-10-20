// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Before an UNAVAILABLE retry behind RpcClientConnection, RpcRetryInterceptor
// waits for the connection's next reconnect attempt, up to 5 s away. The wait
// ends with the call: at its deadline, or when it is cancelled.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

void main() {
  late RpcClientConnection connection;

  setUp(() async {
    var down = false;
    late _T live;
    connection = RpcClientConnection(
      transportFactory: () async {
        if (down) throw StateError('server down');
        return live = _T();
      },
      // The next attempt is far beyond the reconnect wait's own 5 s limit.
      backoff: const FixedBackoff(Duration(seconds: 30)),
    );
    addTearDown(connection.dispose);
    connection.connect();
    await connection.state.firstWhere((s) => s is RpcClientOnline);
    down = true;
    live.drop();
    await connection.state.firstWhere((s) => s is RpcClientConnecting);
  });

  test('the wait ends at the call deadline', () async {
    final (outcome, ms) = await _call(
      connection.transport,
      RpcContext.withTimeout(const Duration(seconds: 1)),
    );
    expect(outcome, isA<RpcDeadlineExceededException>());
    expect(ms, lessThan(2000), reason: 'held past the deadline: $ms ms');
  });

  // A Timer drops the sub-millisecond part of its duration, so one armed for
  // the time left can fire just before the deadline; the attempt after it
  // then sees time left and fails UNAVAILABLE.
  test('the wait ends after the deadline, not just before it', () async {
    for (var i = 0; i < 300; i++) {
      final left = <Duration?>[];
      await _call(
        connection.transport,
        RpcContext.withTimeout(const Duration(milliseconds: 5)),
        backoff: const Duration(milliseconds: 1),
        onAttempt: left.add,
      );
      // A call that started late gives up before the backoff, and makes one
      // attempt; one that waited must find its deadline passed.
      if (left.length > 1) expect(left[1], Duration.zero, reason: 'call $i');
    }
  });

  // The wait re-reads the context's clock to catch a Timer firing a sliver
  // early; a clock that jumps back must not stretch it to the reconnect's own
  // 5 s limit.
  test('a clock that jumps back does not extend the wait', () async {
    var offset = Duration.zero;
    final ctx = RpcContext.empty()
        .withClock(() => DateTime.now().add(offset))
        .withTimeout(const Duration(seconds: 1));
    Timer(const Duration(milliseconds: 300), () {
      offset = const Duration(hours: -1);
    });
    final (_, ms) = await _call(connection.transport, ctx);
    expect(ms, lessThan(2000), reason: 'held past the deadline: $ms ms');
  });

  test('the wait ends when the call is cancelled', () async {
    final token = RpcCancellationToken();
    Timer(const Duration(milliseconds: 300), () => token.cancel('x'));
    final (outcome, ms) = await _call(
      connection.transport,
      RpcContext.withCancellation(token),
    );
    expect(outcome, isA<RpcCancelledException>());
    expect(ms, lessThan(1500), reason: 'held past the cancel: $ms ms');
  });

  test('GUARD with no deadline the reconnect is waited for', () async {
    final (outcome, ms) = await _call(connection.transport, RpcContext.empty());
    expect(outcome, isA<RpcStatusException>());
    expect(ms, greaterThanOrEqualTo(4500));
  });

  // Past the web's timer ceiling (2^31 - 1 ms, about 24.86 days) a plain Timer
  // fires at once there, which would end the wait before the reconnect.
  test('a deadline past the web timer ceiling waits like none', () async {
    final (outcome, ms) = await _call(
      connection.transport,
      RpcContext.withTimeout(const Duration(days: 30)),
    );
    expect(outcome, isA<RpcStatusException>());
    expect(ms, greaterThanOrEqualTo(4500), reason: 'the wait ended early');
  });
}

/// The outcome and elapsed milliseconds of one call through a retry
/// interceptor whose every attempt fails UNAVAILABLE, or the call's own
/// deadline or cancellation once those have passed.
Future<(Object?, int)> _call(
  IRpcTransport transport,
  RpcContext ctx, {
  Duration backoff = const Duration(milliseconds: 100),
  void Function(Duration? left)? onAttempt,
}) async {
  final call = RpcMiddlewareContext(
    endpoint: RpcCallerEndpoint(transport: transport),
    serviceName: 'Svc',
    methodName: 'm',
    context: ctx,
  );
  final retry = RpcRetryInterceptor(
    maxAttempts: 2,
    backoff: FixedBackoff(backoff),
  );
  final sw = Stopwatch()..start();
  Object? outcome;
  try {
    await retry.interceptUnary<String, String>(call, 'r', (c, r) async {
      c.cancellationToken?.throwIfCancelled();
      final left = c.remainingTime;
      onAttempt?.call(left);
      if (left != null && left <= Duration.zero) {
        throw RpcDeadlineExceededException(c.deadline!);
      }
      throw RpcStatusException(RpcStatus.unavailable, 'gone');
    });
  } catch (e) {
    outcome = e;
  }
  return (outcome, sw.elapsedMilliseconds);
}

final class _T extends IRpcTransport {
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  bool _closed = false;

  void drop() {
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _incoming.stream.where((m) => m.streamId == streamId);

  @override
  int createStream() => 1;

  @override
  int get lastIssuedStreamId => 1;

  @override
  void resumeStreamIdsAfter(int streamId) {}

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _closed = true;
    drop();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 't');
}
