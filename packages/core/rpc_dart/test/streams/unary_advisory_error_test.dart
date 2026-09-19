// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `UnaryResponder` listens to the CONNECTION-WIDE broadcast, and its `onError`
// answered every unhandled stream with a trailer. An ADVISORY error says one
// frame was discarded over a connection that still works — a proxy's app-level
// keepalive arriving as a text frame is the real case — so answering it fails
// calls for nothing.
//
// `RpcChannelTransport` already withholds advisory errors from its per-stream
// controllers (`channel_transport.dart:182`). This listener is on the broadcast,
// where they still arrive.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
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
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();
}

/// A responder with a live stream state that has NOT been answered — the only
/// state `onError` acts on. Reached by delivering the call's metadata frame and
/// nothing else, which is the gap between a peer's HEADERS and its DATA.
Future<(_InjectingTransport, UnaryResponder<RpcString, RpcString>)>
_armed() async {
  final (rawClient, rawServer) = RpcChannelTransport.pair();
  final transport = _InjectingTransport(rawServer);

  final responder = UnaryResponder<RpcString, RpcString>(
    id: 1,
    transport: transport,
    serviceName: 'S',
    methodName: 'M',
    requestCodec: _codec,
    responseCodec: _codec,
    handler: (r) async => r,
  );

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
