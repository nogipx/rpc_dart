// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 3: TransportRouter.sendMetadata leaks state when the target
// transport's sendMetadata throws.
//
// transport_router.dart:361-378:
//
//   _streamTransports[streamId] = transport;                 // 361
//   _clientToServerStreamMapping[streamId] = serverStreamId; // 362
//   _subscribeToResponsesForStream(streamId, serverStreamId, transport); // 370
//   await transport.sendMetadata(serverStreamId, metadata, ...);         // 374
//
// If sendMetadata (374) throws, none of the mappings/subscription added at
// 361/362/370 nor the createStream() server slot (354) are rolled back. The
// stream slot leaks: it counts toward _maxActiveStreams and the subscription
// stays registered.
//
// We observe the leak via health().details['activeStreams'] (line 528) which
// reports _streamTransports.length, and via the _maxActiveStreams limit.
//
// CONFIRMED if activeStreams > 0 after the failed send.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Minimal client-side transport whose sendMetadata always throws.
class _ThrowingTransport implements IRpcTransport {
  final _idManager = RpcStreamIdManager(isClient: true); // odd IDs
  final _controller = StreamController<RpcTransportMessage>.broadcast();

  @override
  bool get isClient => true;

  @override
  bool get isClosed => false;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => _idManager.generateId();

  @override
  bool releaseStreamId(int streamId) => _idManager.releaseId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    throw StateError('sendMetadata deliberately failing');
  }

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
  Stream<RpcTransportMessage> get incomingMessages => _controller.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    await _controller.close();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'throwing', message: 'ok');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'throwing', message: 'ok');
}

void main() {
  test('sendMetadata leaks stream slot when target throws', () async {
    final target = _ThrowingTransport();

    final router = RpcTransportRouterBuilder()
        .maxActiveStreams(1)
        .routeWhen(
          toTransport: target,
          whenCondition: (serviceName, methodPath, context) => true,
          description: 'route everything to throwing transport',
        )
        .build();

    final metadata = RpcMetadata.forClientRequest('Svc', 'Method');

    // Drive a send that fails inside transport.sendMetadata.
    await expectLater(
      router.sendMetadata(1, metadata),
      throwsA(isA<StateError>()),
    );

    // Correct behavior: a failed send must not leave a registered stream.
    final health = await router.health();
    final activeStreams = health.details['activeStreams'];

    expect(
      activeStreams,
      0,
      reason: 'failed sendMetadata must roll back _streamTransports / '
          '_clientToServerStreamMapping / subscription; leaked slot found',
    );

    await router.close();
    await target.close();
  });

  test('leaked slot blocks subsequent sends at maxActiveStreams=1', () async {
    final target = _ThrowingTransport();
    final router = RpcTransportRouterBuilder()
        .maxActiveStreams(1)
        .routeWhen(
          toTransport: target,
          whenCondition: (serviceName, methodPath, context) => true,
          description: 'route all',
        )
        .build();

    final metadata = RpcMetadata.forClientRequest('Svc', 'Method');

    // First send fails inside the transport.
    await expectLater(
      router.sendMetadata(1, metadata),
      throwsA(isA<StateError>()),
    );

    // A second, different stream should NOT hit the activeStreams limit if the
    // first (failed) one was cleaned up. If the slot leaked, this throws an
    // RpcException about the activeStreams limit instead of the StateError.
    try {
      await router.sendMetadata(3, metadata);
      fail('expected the transport StateError on the second send');
    } on StateError {
      // Good: reached the transport again -> no leak blocking us.
    } on RpcException catch (e) {
      fail('leaked slot blocked second send: $e');
    }

    await router.close();
    await target.close();
  });
}
