// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Req implements IRpcSerializable {
  _Req(this.value);
  final String value;
  factory _Req.fromJson(Map<String, dynamic> json) =>
      _Req(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

class _Resp implements IRpcSerializable {
  _Resp(this.value);
  final String value;
  factory _Resp.fromJson(Map<String, dynamic> json) =>
      _Resp(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

/// Client-stream service that records every request value it receives.
final class _CollectService extends RpcResponderContract {
  _CollectService() : super('CollectService');

  final List<String> received = [];
  final Completer<void> done = Completer<void>();

  @override
  void setup() {
    addClientStreamMethod<_Req, _Resp>(
      methodName: 'Collect',
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
      handler: (requests, {context}) async {
        await for (final r in requests) {
          received.add(r.value);
        }
        if (!done.isCompleted) done.complete();
        return _Resp('ok');
      },
    );
  }
}

/// Transport whose [incomingMessages] the test drives directly, in any order —
/// reproducing the broadcast-transport frame reordering the endpoint sees.
final class _ControllableTransport extends IRpcTransport {
  final _controller = StreamController<RpcTransportMessage>.broadcast();
  bool _closed = false;

  void deliver(RpcTransportMessage message) => _controller.add(message);

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _controller.stream;

  @override
  int createStream() => 2;

  @override
  bool releaseStreamId(int streamId) => true;

  // Responder sends its reply/trailers here — irrelevant to the test.
  @override
  Future<void> sendMetadata(int s, RpcMetadata m, {bool endStream = false}) async {}

  @override
  Future<void> sendMessage(int s, Uint8List d, {bool endStream = false}) async {}

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _closed = true;
    await _controller.close();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'ControllableTransport');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'ControllableTransport');
}

void main() {
  group('Responder pre-method frame buffering (broadcast reorder)', () {
    late _ControllableTransport transport;
    late RpcResponderEndpoint responder;
    late _CollectService service;
    final codec = RpcCodec<_Req>(_Req.fromJson);

    setUp(() {
      transport = _ControllableTransport();
      responder = RpcResponderEndpoint(transport: transport);
      service = _CollectService();
      responder.registerServiceContract(service);
      responder.start();
    });

    tearDown(() async {
      await responder.close();
    });

    Uint8List frame(String v) =>
        RpcMessageFrame.encode(codec.serialize(_Req(v)));

    RpcTransportMessage data(String v, int sid, {bool eos = false}) =>
        RpcTransportMessage.withPayload(
          payload: frame(v),
          isEndOfStream: eos,
          streamId: sid,
        );

    RpcTransportMessage meta(int sid) => RpcTransportMessage.withMetadata(
          metadata: RpcMetadata(const [], methodPath: '/CollectService/Collect'),
          methodPath: '/CollectService/Collect',
          streamId: sid,
        );

    test('payload arriving before metadata is buffered, not dropped', () async {
      const sid = 2;
      // Data frame BEFORE the metadata (headers) frame.
      transport.deliver(data('a', sid));
      transport.deliver(meta(sid));
      transport.deliver(data('b', sid, eos: true));

      await service.done.future.timeout(const Duration(seconds: 5));
      expect(service.received, ['a', 'b']);
    });

    test('single chunk + EOS before metadata is still delivered', () async {
      const sid = 2;
      transport.deliver(data('solo', sid, eos: true));
      transport.deliver(meta(sid));

      await service.done.future.timeout(const Duration(seconds: 5));
      expect(service.received, ['solo']);
    });

    test('normal order (metadata first) still works', () async {
      const sid = 2;
      transport.deliver(meta(sid));
      transport.deliver(data('x', sid));
      transport.deliver(data('y', sid, eos: true));

      await service.done.future.timeout(const Duration(seconds: 5));
      expect(service.received, ['x', 'y']);
    });
  });
}