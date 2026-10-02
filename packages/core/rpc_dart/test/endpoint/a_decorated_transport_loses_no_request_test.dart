// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A decorator that re-broadcasts `incomingMessages` asynchronously puts one turn
// between the transport and the responder pipeline. A streaming call the peer
// opened used to read its requests from the transport's per-stream view, which
// gets a frame only if it exists when the frame is dispatched, and the pipeline
// creates it on the opening frame, one turn late. Every request went to the
// broadcast alone, which a bound call ignored.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Forwards everything, with `incomingMessages` delayed by a timer, as a
/// decorator that does real asynchronous work per frame would.
final class _AsyncDecorator extends IRpcTransport {
  _AsyncDecorator(this._inner);

  final IRpcTransport _inner;

  @override
  late final Stream<RpcTransportMessage> incomingMessages = _inner
      .incomingMessages
      .asyncMap((m) async {
        await Future<void>.delayed(Duration.zero);
        return m;
      });

  @override
  bool get isClient => _inner.isClient;
  @override
  bool get isClosed => _inner.isClosed;
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

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield 'echo ${r.value}'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Watch',
      handler: (request, {RpcContext? context}) async* {
        yield 'watched ${request.value}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A server peer calls the client peer, whose transport may be [decorated].
Future<List<String>> _calls({required bool decorated}) async {
  final (a, b) = RpcFrameMultiplexedChannel.pair();
  final IRpcTransport clientTransport = RpcChannelTransport(
    channel: a,
    isClient: true,
  );
  final serverTransport = RpcChannelTransport(channel: b, isClient: false);
  final clientPeer = RpcPeerEndpoint(
    transport: decorated ? _AsyncDecorator(clientTransport) : clientTransport,
  )..registerServiceContract(_Svc());
  clientPeer.start();
  final serverPeer = RpcPeerEndpoint(transport: serverTransport)..start();

  Future<String> first(Stream<RpcString> s) => s.first
      .timeout(const Duration(seconds: 3))
      .then((r) => r.value, onError: (Object e) => 'TIMEOUT');

  final requests = StreamController<RpcString>()..add('hi'.rpc);
  final got = [
    await first(
      serverPeer.bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Chat',
        requests: requests.stream,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
    ),
    await first(
      serverPeer.serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Watch',
        request: 'it'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
    ),
  ];
  await requests.close();
  await serverPeer.close();
  await clientPeer.close();
  return got;
}

void main() {
  test('a peer call through an async decorator gets its requests', () async {
    expect(await _calls(decorated: true), ['echo hi', 'watched it']);
  });

  test('CONTROL: the same calls on the undecorated transport', () async {
    expect(await _calls(decorated: false), ['echo hi', 'watched it']);
  });
}
