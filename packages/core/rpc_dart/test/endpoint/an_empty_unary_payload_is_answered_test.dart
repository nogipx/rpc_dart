// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary call whose only DATA frame is empty, then a half-close, was never
// answered and held its stream slot until the peer disconnected. The responder
// waits after an empty chunk, the parser buffers nothing, and
// `isAwaitingRequest` asked the parser alone -- so the half-close reached no
// branch that answers. Repeated on fresh ids it fills `maxActiveStreams` and
// every later call on that connection is refused.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Chan implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  final sent = <Uint8List>[];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('closed');
    sent.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _in.close();
  }

  void feed(Uint8List b) {
    if (!_closed) _in.add(b);
  }
}

typedef _Outcome = ({String? status, String? message, int held});

/// Opens one unary call on stream 1, sends [payload] (if any) and half-closes.
Future<_Outcome> _call(Uint8List? payload) async {
  final chan = _Chan();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: false,
  );
  final responder = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_Svc())
    ..start();
  addTearDown(() async {
    await responder.close();
    await transport.close();
  });

  chan.feed(
    RpcChannelFrame.encodeMetadata(
      streamId: 1,
      metadata: RpcMetadata.forClientRequest('Svc', 'u'),
    ),
  );
  await Future<void>.delayed(Duration.zero);
  if (payload != null) {
    chan.feed(RpcChannelFrame.encodeData(streamId: 1, payload: payload));
    await Future<void>.delayed(Duration.zero);
  }
  chan.feed(RpcChannelFrame.encodeEndOfStream(1));

  String? status;
  String? message;
  for (var w = 0; w < 100 && status == null; w++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    for (final f in chan.sent) {
      final d = RpcChannelFrame.decode(f);
      final s = d?.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      if (d?.streamId == 1 && s != null) {
        status = s;
        final raw = d?.metadata?.getHeaderValue(RpcHeaders.grpcMessage);
        message = raw == null ? null : Uri.decodeComponent(raw);
      }
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return (
    status: status,
    message: message,
    held: responder.activeResponderCount,
  );
}

void main() {
  final full = RpcMessageFrame.encode(_codec.serialize('hi'.rpc));

  test('an empty payload then a half-close is answered and released', () async {
    // WITNESS. Before the fix: no status at all, and one responder held.
    final r = await _call(Uint8List(0));
    expect(r.status, '${RpcStatus.invalidArgument}');
    expect(r.message, contains('empty payload frame'));
    expect(r.held, 0);
  });

  test('GUARD: a frame cut mid-message keeps its own answer', () async {
    final r = await _call(Uint8List.sublistView(full, 0, 5));
    expect(r.status, '${RpcStatus.invalidArgument}');
    expect(r.message, contains('mid-message'));
    expect(r.held, 0);
  });

  test('GUARD: an empty chunk followed by the request still runs it', () async {
    // The wait after an empty chunk is deliberate; the fix must not turn it
    // into a refusal.
    final chan = _Chan();
    final transport = RpcChannelTransport.fromChannel(
      channel: chan,
      isClient: false,
    );
    final responder = RpcResponderEndpoint(transport: transport)
      ..registerServiceContract(_Svc())
      ..start();
    addTearDown(() async {
      await responder.close();
      await transport.close();
    });
    chan
      ..feed(
        RpcChannelFrame.encodeMetadata(
          streamId: 1,
          metadata: RpcMetadata.forClientRequest('Svc', 'u'),
        ),
      )
      ..feed(RpcChannelFrame.encodeData(streamId: 1, payload: Uint8List(0)))
      ..feed(
        RpcChannelFrame.encodeData(
          streamId: 1,
          payload: full,
          endOfStream: true,
        ),
      );
    String? status;
    for (var w = 0; w < 100 && status == null; w++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final f in chan.sent) {
        final d = RpcChannelFrame.decode(f);
        if (d?.streamId == 1) {
          status ??= d?.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
        }
      }
    }
    expect(status, '0');
  });
}
