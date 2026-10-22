// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcRetryInterceptor waits for RpcClientConnection's next reconnect before it
// retries an UNAVAILABLE call. A transport decorator -- logging, metrics --
// implements IRpcTransport and forwards every member, so wrapping the
// connection's transport must keep that wait: the retry asks the transport it
// was given, and the decorator is that transport.
//
// The connection drops, the server is back at once, and the connection
// reconnects after its 100 ms backoff. The retry backoff is 10 ms, so three
// attempts that do not wait all land on the dead connection.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'say',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

/// Forwards every member of [IRpcTransport], as a decorator must.
final class _Forwarding implements IRpcTransport {
  _Forwarding(this.inner);

  final IRpcTransport inner;

  @override
  bool get isClient => inner.isClient;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get supportsZeroCopy => inner.supportsZeroCopy;
  @override
  int createStream() => inner.createStream();
  @override
  bool releaseStreamId(int streamId) => inner.releaseStreamId(streamId);
  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => inner.sendMetadata(streamId, metadata, endStream: endStream);
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => inner.sendMessage(streamId, data, endStream: endStream);
  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) => inner.sendDirectObject(streamId, object, endStream: endStream);
  @override
  Stream<RpcTransportMessage> get incomingMessages => inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      inner.getMessagesForStream(streamId);
  @override
  Future<void> finishSending(int streamId) => inner.finishSending(streamId);
  @override
  Future<void> close() => inner.close();
  @override
  Future<RpcHealthStatus> health() => inner.health();
  @override
  int get lastIssuedStreamId => inner.lastIssuedStreamId;
  @override
  bool get supportsStreamIdResume => inner.supportsStreamIdResume;

  @override
  void resumeStreamIdsAfter(int streamId) =>
      inner.resumeStreamIdsAfter(streamId);
  @override
  RpcSecurityPolicy get securityPolicy => inner.securityPolicy;
  @override
  Future<void> get ready => inner.ready;
  @override
  Future<bool> resetStream(int streamId, {String? reason}) =>
      inner.resetStream(streamId, reason: reason);
  @override
  IRpcFlowCredit? get flowCredit => inner.flowCredit;
  @override
  bool get grantsMessageCredit => inner.grantsMessageCredit;
  @override
  IRpcConnectionBuffer? get connectionBuffer => inner.connectionBuffer;
  @override
  IRpcReconnectOutcome? get reconnectOutcome => inner.reconnectOutcome;
}

void main() {
  for (final decorated in [false, true]) {
    final arm = decorated ? 'decorated' : 'CONTROL bare';

    test('$arm: a retry waits for the reconnect and succeeds', () async {
      final servers = <RpcResponderEndpoint>[];
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          final (client, server) = RpcChannelTransport.memoryPair();
          servers.add(
            RpcResponderEndpoint(transport: server)
              ..registerServiceContract(_Echo())
              ..start(),
          );
          return client;
        },
        backoff: const RpcFixedBackoff(Duration(milliseconds: 100)),
      );
      addTearDown(() async {
        await connection.dispose();
        for (final s in servers) {
          await s.close();
        }
      });
      connection.connect();
      await connection.state.firstWhere((s) => s is RpcClientOnline);

      final transport = decorated
          ? _Forwarding(connection.transport)
          : connection.transport;
      final caller = RpcCallerEndpoint(transport: transport)
        ..addInterceptor(
          RpcRetryInterceptor(
            backoff: const RpcFixedBackoff(Duration(milliseconds: 10)),
          ),
        );
      addTearDown(caller.close);

      // The server side of the live connection goes away.
      await servers.single.close();
      await connection.state.firstWhere((s) => s is RpcClientOffline);

      final response = await caller
          .unary<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'say',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
      expect(response.value, 'hi');
    });
  }
}
