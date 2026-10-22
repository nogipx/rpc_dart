// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcResponderEndpoint` listens to the CONNECTION-WIDE broadcast, and a
// transport error there is answered with a trailer on every unanswered
// stream. An ADVISORY error says one frame was discarded over a connection
// that still works — a proxy's app-level keepalive arriving as a text frame is
// the real case — so answering it would fail calls for nothing.
//
// `RpcChannelTransport` withholds advisory errors from its per-stream
// controllers. The endpoint's listener is on the broadcast, where they still
// arrive.

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// What a channel raises when it discarded one frame but is still working.
final class _Advisory extends RpcException implements IRpcAdvisoryChannelError {
  _Advisory() : super('one frame discarded; the connection still works');
}

/// A real failure of the connection.
final class _Fatal extends RpcException {
  _Fatal() : super('the connection is gone');
}

/// Lets the test push errors into the responder's broadcast, and records the
/// trailers the responder sends back.
final class _InjectingTransport implements IRpcTransport {
  _InjectingTransport(this._inner);

  final IRpcTransport _inner;
  final _ctl = StreamController<RpcTransportMessage>.broadcast();

  /// Trailers the responder sent, by stream id.
  final List<int> trailers = [];

  void inject(Object error) => _ctl.addError(error);
  void deliver(RpcTransportMessage message) => _ctl.add(message);

  @override
  Stream<RpcTransportMessage> get incomingMessages => _ctl.stream;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (metadata.getHeaderValue(RpcHeaders.grpcStatus) != null) {
      trailers.add(streamId);
    }
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

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
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);
  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);
  @override
  Future<void> close() => _inner.close();
  @override
  Future<RpcHealthStatus> health() => _inner.health();
  @override
  int get lastIssuedStreamId => _inner.lastIssuedStreamId;
  @override
  bool get supportsStreamIdResume => _inner.supportsStreamIdResume;

  @override
  void resumeStreamIdsAfter(int streamId) =>
      _inner.resumeStreamIdsAfter(streamId);
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
  IRpcReconnectOutcome? get reconnectOutcome => _inner.reconnectOutcome;
}

/// Service `S`, unary `M`: echoes its request.
final class _Echo extends RpcResponderContract {
  _Echo() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'M',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// An endpoint with a live stream that has NOT been answered — the only state
/// a transport error is answered on. Reached by delivering the call's metadata
/// frame and nothing else, which is the gap between a peer's HEADERS and its
/// DATA.
Future<(_InjectingTransport, RpcResponderEndpoint)> _armed() async {
  final (rawClient, rawServer) = RpcChannelTransport.pair();
  final transport = _InjectingTransport(rawServer);

  final responder = RpcResponderEndpoint(transport: transport);
  responder.registerServiceContract(_Echo());
  responder.start();
  // The endpoint subscribes to the broadcast asynchronously; a frame
  // delivered before that is dropped.
  await Future<void>.delayed(const Duration(milliseconds: 10));

  transport.deliver(
    RpcTransportMessage(
      streamId: 1,
      methodPath: '/S/M',
      metadata: RpcMetadata.forClientRequest('S', 'M'),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 20));

  addTearDown(() async {
    await responder.close().catchError((_) {});
    await rawClient.close();
    await rawServer.close();
  });
  return (transport, responder);
}

void main() {
  test('WITNESS: an advisory error does not fail a waiting call', () async {
    final (transport, _) = await _armed();

    transport.inject(_Advisory());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      transport.trailers,
      isEmpty,
      reason:
          'a discarded frame over a working connection answered the call with '
          'a trailer: streams ${transport.trailers}',
    );
  });

  test('GUARD: a real transport error still answers the call', () async {
    // The path the advisory check must not take away.
    final (transport, _) = await _armed();

    transport.inject(_Fatal());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      transport.trailers,
      contains(1),
      reason: 'the caller was left waiting on a dead connection',
    );
  });
}
