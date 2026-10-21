// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dispose() and disconnect() end the connect attempt in flight, not only the
// connection around it. A transport already handed over but not yet ready is
// closed at once; a factory still working is told through its cancellation
// token; and the loop stops waiting either way, so connect() after a
// disconnect() starts a fresh attempt instead of finding the old one stuck.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// A transport whose `ready` never completes, recording its close.
final class _NeverReady implements IRpcTransport {
  _NeverReady(this.inner);
  final IRpcTransport inner;
  final closed = Completer<void>();

  @override
  Future<void> get ready => Completer<void>().future;
  @override
  Future<void> close() {
    if (!closed.isCompleted) closed.complete();
    return inner.close();
  }

  @override
  bool get isClient => inner.isClient;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get supportsZeroCopy => inner.supportsZeroCopy;
  @override
  Stream<RpcTransportMessage> get incomingMessages => inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      inner.getMessagesForStream(id);
  @override
  int createStream() => inner.createStream();
  @override
  bool releaseStreamId(int id) => inner.releaseStreamId(id);
  @override
  Future<void> sendMetadata(int id, RpcMetadata m, {bool endStream = false}) =>
      inner.sendMetadata(id, m, endStream: endStream);
  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      inner.sendMessage(id, d, endStream: endStream);
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      inner.sendDirectObject(id, o, endStream: endStream);
  @override
  Future<void> finishSending(int id) => inner.finishSending(id);
  @override
  Future<RpcHealthStatus> health() => inner.health();
  @override
  int get lastIssuedStreamId => inner.lastIssuedStreamId;
  @override
  void resumeStreamIdsAfter(int id) => inner.resumeStreamIdsAfter(id);
  @override
  RpcSecurityPolicy get securityPolicy => inner.securityPolicy;
  @override
  Future<bool> resetStream(int id, {String? reason}) =>
      inner.resetStream(id, reason: reason);
  @override
  IRpcFlowCredit? get flowCredit => inner.flowCredit;
  @override
  bool get grantsMessageCredit => inner.grantsMessageCredit;
  @override
  IRpcConnectionBuffer? get connectionBuffer => inner.connectionBuffer;
  @override
  IRpcReconnectOutcome? get reconnectOutcome => inner.reconnectOutcome;
}

/// Whether [f] completes within [within].
Future<bool> _within(Future<void> f, Duration within) => Future.any([
  f.then((_) => true),
  Future<bool>.delayed(within, () => false),
]);

const _soon = Duration(seconds: 1);

void main() {
  test('dispose closes a transport still waiting to be ready', () async {
    final factoryCalled = Completer<_NeverReady>();
    final connection = RpcClientConnection(
      connectTimeout: null, // nothing else would ever end the wait
      transportFactory: () async {
        final (client, _) = RpcChannelTransport.memoryPair();
        final t = _NeverReady(client);
        factoryCalled.complete(t);
        return t;
      },
    );
    connection.connect();
    final transport = await factoryCalled.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await connection.dispose();
    expect(
      await _within(transport.closed.future, _soon),
      isTrue,
      reason: 'a transport the attempt already held stayed open after dispose',
    );
  });

  test('dispose cancels the token of a factory still working', () async {
    final token = Completer<RpcCancellationToken>();
    final connection = RpcClientConnection.cancellable(
      connectTimeout: null,
      transportFactory: (cancellation) {
        token.complete(cancellation);
        return Completer<IRpcTransport>().future; // never answers
      },
    );
    connection.connect();
    final cancellation = await token.future;
    expect(cancellation.isCancelled, isFalse);

    await connection.dispose();
    expect(cancellation.isCancelled, isTrue);
  });

  test('connectTimeout cancels the token of the attempt it ends', () async {
    final token = Completer<RpcCancellationToken>();
    final connection = RpcClientConnection.cancellable(
      connectTimeout: const Duration(milliseconds: 50),
      maxAttempts: 1,
      transportFactory: (cancellation) {
        if (!token.isCompleted) token.complete(cancellation);
        return Completer<IRpcTransport>().future;
      },
    );
    addTearDown(connection.dispose);
    connection.connect();
    final cancellation = await token.future;
    expect(await _within(cancellation.cancelled, _soon), isTrue);
  });

  test('connect after a disconnect mid-attempt comes back online', () async {
    var calls = 0;
    final errors = <Object?>[];
    final firstCalled = Completer<void>();
    final connection = RpcClientConnection.cancellable(
      connectTimeout: null,
      shouldReconnect: (e) {
        errors.add(e);
        return true;
      },
      transportFactory: (cancellation) async {
        if (++calls == 1) {
          firstCalled.complete();
          return Completer<IRpcTransport>().future; // the stuck attempt
        }
        final (client, _) = RpcChannelTransport.memoryPair();
        return client;
      },
    );
    addTearDown(connection.dispose);
    final online = connection.state.firstWhere((s) => s is RpcClientOnline);

    connection.connect();
    await firstCalled.future;
    await connection.disconnect();
    connection.connect();

    expect(
      await _within(online, _soon),
      isTrue,
      reason:
          'the stuck attempt held the loop, so connect() never started '
          'a new one',
    );
    expect(calls, 2);
    expect(
      errors,
      isEmpty,
      reason: 'an attempt the stop gave up is not a failure to judge',
    );
  });
}
