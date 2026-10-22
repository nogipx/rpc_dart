// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpointBase', () {
    test('health maps transport levels and includes debug label', () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        healthResult: RpcHealthStatus.reconnecting(component: 'transport'),
      );

      final endpoint = RpcCallerEndpoint(
        transport: transport,
        debugLabel: 'dbg',
      );
      addTearDown(() async => endpoint.close());

      final report = await endpoint.health();

      expect(report.endpointStatus.level, RpcHealthLevel.reconnecting);
      expect(report.endpointStatus.details['debugLabel'], equals('dbg'));
      expect(
        report.endpointStatus.details['transportType'],
        equals('_ConfigurableTransport'),
      );
    });

    test('health is unhealthy when transport.health throws', () async {
      final transport = _ConfigurableTransport(
        isClient: true,
        throwOnHealth: true,
      );

      final endpoint = RpcCallerEndpoint(transport: transport);
      addTearDown(() async => endpoint.close());

      final report = await endpoint.health();

      expect(report.transportStatus.level, RpcHealthLevel.unhealthy);
      expect(report.endpointStatus.level, RpcHealthLevel.unhealthy);
      expect(report.transportStatus.details['isClosed'], isFalse);
    });

    test(
      'health is closed when transport.health throws and transport closed',
      () async {
        final transport = _ConfigurableTransport(
          isClient: true,
          isClosed: true,
          throwOnHealth: true,
        );

        final endpoint = RpcCallerEndpoint(transport: transport);
        addTearDown(() async => endpoint.close());

        final report = await endpoint.health();

        expect(report.transportStatus.level, RpcHealthLevel.closed);
        expect(report.endpointStatus.level, RpcHealthLevel.degraded);
        expect(report.transportStatus.details['isClosed'], isTrue);
      },
    );

    test(
      'close swallows transport.close error and deactivates endpoint',
      () async {
        final transport = _ConfigurableTransport(
          isClient: true,
          throwOnClose: true,
        );

        final endpoint = RpcCallerEndpoint(transport: transport);

        await endpoint.close();
        await endpoint.close();

        expect(endpoint.isActive, isFalse);
      },
    );
  });
}

final class _ConfigurableTransport extends IRpcTransport {
  final bool _isClient;
  bool _isClosed;

  bool throwOnHealth;
  bool throwOnClose;

  RpcHealthStatus healthResult;

  _ConfigurableTransport({
    required bool isClient,
    bool isClosed = false,
    this.throwOnHealth = false,
    this.throwOnClose = false,
    RpcHealthStatus? healthResult,
  }) : _isClient = isClient,
       _isClosed = isClosed,
       healthResult =
           healthResult ??
           RpcHealthStatus.healthy(component: '_ConfigurableTransport');

  @override
  bool get isClient => _isClient;

  @override
  bool get isClosed => _isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => 1;

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
  }) async {
    throw UnsupportedError('Zero-copy not supported');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      const Stream<RpcTransportMessage>.empty();

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((message) => message.streamId == streamId);

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _isClosed = true;
    if (throwOnClose) throw StateError('close failed');
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (throwOnHealth) throw StateError('health failed');
    return healthResult;
  }

  @override
  int get lastIssuedStreamId => 0;

  @override
  bool get supportsStreamIdResume => true;

  @override
  void resumeStreamIdsAfter(int streamId) {}
}
