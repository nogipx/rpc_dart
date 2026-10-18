// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The app's level is built from each endpoint's typed health, so a transport
// that reports itself reconnecting or degraded degrades the app. Reading only
// whether the endpoint is active reported such an app as healthy.

import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

/// Forwards to [_inner] and reports [_level] as its health.
final class _Reporting implements IRpcTransport {
  _Reporting(this._inner, this._level);

  final IRpcTransport _inner;
  final RpcHealthLevel _level;

  @override
  Future<RpcHealthStatus> health() async => switch (_level) {
    RpcHealthLevel.healthy => RpcHealthStatus.healthy(component: 'test'),
    RpcHealthLevel.degraded => RpcHealthStatus.degraded(component: 'test'),
    RpcHealthLevel.reconnecting => RpcHealthStatus.reconnecting(
      component: 'test',
    ),
    RpcHealthLevel.unhealthy => RpcHealthStatus.unhealthy(component: 'test'),
    RpcHealthLevel.closed => RpcHealthStatus.closed(component: 'test'),
  };

  @override
  bool get isClient => _inner.isClient;
  @override
  bool get isClosed => _inner.isClosed;
  @override
  bool get supportsZeroCopy => _inner.supportsZeroCopy;
  @override
  int createStream() => _inner.createStream();
  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);
  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => _inner.sendMetadata(streamId, metadata, endStream: endStream);
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => _inner.sendMessage(streamId, data, endStream: endStream);
  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) => _inner.sendDirectObject(streamId, object, endStream: endStream);
  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);
  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);
  @override
  Future<void> close() => _inner.close();
  @override
  RpcSecurityPolicy get securityPolicy => _inner.securityPolicy;
  @override
  Future<void> get ready => _inner.ready;
  @override
  Future<bool> resetStream(int streamId, {String? reason}) =>
      _inner.resetStream(streamId, reason: reason);
  @override
  IRpcFlowCredit? get flowCredit => _inner.flowCredit;
  @override
  bool get grantsMessageCredit => _inner.grantsMessageCredit;
  @override
  IRpcConnectionBuffer? get connectionBuffer => _inner.connectionBuffer;
  @override
  int get lastIssuedStreamId => _inner.lastIssuedStreamId;
  @override
  void resumeStreamIdsAfter(int streamId) =>
      _inner.resumeStreamIdsAfter(streamId);
}

final class _OneEndpoint implements IRpcServer {
  _OneEndpoint(this._endpoint);
  final RpcResponderEndpoint _endpoint;
  @override
  bool get isRunning => true;
  @override
  List<RpcResponderEndpoint> get endpoints => [_endpoint];
  @override
  Future<void> start() async {}
  @override
  Future<void> stop({Duration? drainTimeout}) async {}
}

class _Module extends RpcModule {
  @override
  String get name => 'Module';
}

Future<RpcAppHealthLevel> _appLevel(RpcHealthLevel transport) async {
  final (client, server) = RpcChannelTransport.memoryPair();
  final endpoint = RpcResponderEndpoint(
    transport: _Reporting(server, transport),
  )..start();
  final app = RpcApp.server(
    modules: [_Module()],
    server: (_) => _OneEndpoint(endpoint),
  );
  await app.start();
  addTearDown(() async {
    await app.stop();
    await endpoint.close();
    await client.close();
  });
  return (await app.health()).level;
}

void main() {
  test('WITNESS: a reconnecting transport degrades the app', () async {
    expect(
      await _appLevel(RpcHealthLevel.reconnecting),
      RpcAppHealthLevel.degraded,
    );
  });

  test('WITNESS: a degraded transport degrades the app', () async {
    expect(
      await _appLevel(RpcHealthLevel.degraded),
      RpcAppHealthLevel.degraded,
    );
  });

  test('WITNESS: an unhealthy transport makes the app unhealthy', () async {
    expect(
      await _appLevel(RpcHealthLevel.unhealthy),
      RpcAppHealthLevel.unhealthy,
    );
  });

  test('CONTROL: a healthy transport keeps the app healthy', () async {
    expect(await _appLevel(RpcHealthLevel.healthy), RpcAppHealthLevel.healthy);
  });
}
