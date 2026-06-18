// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: RpcTransportRouter._subscribeToResponsesForStream did
//   _responseSubscriptions[clientStreamId] = subscription;
// overwriting a possibly still-live subscription without cancelling it. Stream
// IDs are reused over the router's lifetime, so the stale subscription leaked
// and kept forwarding responses from the OLD server stream to the client.
//
// transport_router.dart (~line 128).
//
// Fix: cancel any existing subscription for the key before overwriting.
//
// CONFIRMED-FIX if, after a client stream id is reused (re-routed to a new
// server stream id), a late response on the OLD server stream id is no longer
// forwarded to the client.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart'
    hide
        RpcTransportRouter,
        RpcTransportRouterBuilder,
        RpcRoutingCondition,
        PrioritizedRoutingRule;
import 'package:rpc_notify/src/transport_router.dart';
import 'package:test/test.dart';

/// Client-side transport with a controllable incoming response stream and
/// monotonically increasing server stream ids.
class _ControllableTransport implements IRpcTransport {
  final _idManager = RpcStreamIdManager(isClient: true); // odd ids
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

  void emit(RpcTransportMessage message) => _controller.add(message);

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
      RpcHealthStatus.healthy(component: 'ctl', message: 'ok');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'ctl', message: 'ok');
}

void main() {
  test('reusing a client stream id cancels the prior response subscription',
      () async {
    final target = _ControllableTransport();

    final router = RpcTransportRouterBuilder()
        .routeWhen(
          toTransport: target,
          whenCondition: (serviceName, methodPath, context) => true,
          description: 'route all',
        )
        .build();

    final metadata = RpcMetadata.forClientRequest('Svc', 'Method');

    // First routing for client stream id 1. The target transport allocates the
    // first server stream id (odd ids on a fresh client transport => 1).
    await router.sendMetadata(1, metadata);
    const firstServerId = 1;

    // Re-route the SAME client stream id 1 (id reuse) before any END_STREAM
    // cleanup. This creates a NEW subscription on a NEW server stream id (3)
    // and must cancel the previous subscription bound to server id 1.
    await router.sendMetadata(1, metadata);

    final forwarded = <int>[];
    final sub = router.incomingMessages.listen((m) => forwarded.add(m.streamId));

    // Emit a response on the FIRST (now stale) server stream id. Before the
    // fix, the leaked old subscription is still live and forwards this to
    // client stream 1. After the fix, the old subscription was cancelled, so
    // nothing is forwarded.
    target.emit(
      RpcTransportMessage(
        metadata: metadata,
        streamId: firstServerId,
        isEndOfStream: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      forwarded.where((id) => id == 1),
      isEmpty,
      reason: 'a response on the stale server stream id must not be forwarded; '
          'the prior subscription must be cancelled on stream id reuse',
    );

    await sub.cancel();
    await router.close();
    await target.close();
  });
}
