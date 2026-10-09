// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Before an UNAVAILABLE retry RpcRetryInterceptor waits for the transport's
// reconnect(). Behind RpcClientConnection that is the connection's next
// attempt, up to 5 s away. The wait ends with the call: at its deadline, or
// when it is cancelled.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
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
}

/// The outcome and elapsed milliseconds of one call through a retry
/// interceptor whose every attempt fails UNAVAILABLE, or the call's own
/// deadline or cancellation once those have passed.
Future<(Object?, int)> _call(IRpcTransport transport, RpcContext ctx) async {
  final call = RpcMiddlewareContext(
    endpoint: RpcCallerEndpoint(transport: transport),
    serviceName: 'Svc',
    methodName: 'm',
    context: ctx,
  );
  final retry = RpcRetryInterceptor(
    maxAttempts: 2,
    backoff: const FixedBackoff(Duration(milliseconds: 100)),
  );
  final sw = Stopwatch()..start();
  Object? outcome;
  try {
    await retry.interceptUnary<String, String>(call, 'r', (c, r) async {
      c.cancellationToken?.throwIfCancelled();
      final left = c.remainingTime;
      if (left != null && left <= Duration.zero) {
        throw RpcDeadlineExceededException(c.deadline!, Duration.zero);
      }
      throw RpcStatusException(RpcStatus.unavailable, 'gone');
    });
  } catch (e) {
    outcome = e;
  }
  return (outcome, sw.elapsedMilliseconds);
}

final class _T implements IRpcReconnectableTransport {
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

  @override
  Future<RpcHealthStatus> reconnect() async => health();
}
