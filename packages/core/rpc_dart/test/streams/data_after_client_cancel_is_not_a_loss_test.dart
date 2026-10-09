// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream peer that cancels its call and then sends one more frame --
// its half-close, or a message -- ends a call that is already over, and
// dropping the frame is right. But the cancel tears the stream down after an
// await, and a frame arriving in between reached a responder whose request
// sink the cancel had detached: "Request message DROPPED" and "Request
// messages LOST", both at ERROR, on every call cancelled that way.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
        }
        return '$n'.rpc;
      },
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
  Future<void> send(Uint8List data) async => sent.add(data);

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

final _message = RpcMessageFrame.encode(_codec.serialize('hi'.rpc));

Uint8List _open(int id) => RpcChannelFrame.encodeMetadata(
  streamId: id,
  metadata: RpcMetadata.forClientRequest('Svc', 'c'),
);

Uint8List _data(int id) =>
    RpcChannelFrame.encodeData(streamId: id, payload: _message);

Uint8List _cancel(int id) => RpcChannelFrame.encodeMetadata(
  streamId: id,
  metadata: RpcMetadata([
    RpcHeader(RpcHeaders.xClientCancelled, 'true'),
    RpcHeader(RpcHeaders.xCancellationReason, 'gone'),
  ]),
);

Future<({_Chan chan, List<String> errors})> _start() async {
  final controller = LogController(minLevel: RpcLogLevel.warning);
  final errors = <String>[];
  controller.stream.listen((r) {
    if (r is LogEvent && r.level.index >= RpcLogLevel.error.index) {
      errors.add(r.message);
    }
  });
  final chan = _Chan();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: false,
  );
  final responder =
      RpcResponderEndpoint(transport: transport, logger: controller)
        ..registerServiceContract(_Svc())
        ..start();
  addTearDown(() async {
    await responder.close();
    await transport.close();
  });
  return (chan: chan, errors: errors);
}

void main() {
  for (final after in ['half-close', 'message']) {
    test('a $after after the cancel is dropped without an alarm', () async {
      // WITNESS. Before: a DROPPED and a LOST error per call.
      final s = await _start();
      for (var k = 0; k < 10; k++) {
        final id = 1 + 2 * k;
        s.chan
          ..feed(_open(id))
          ..feed(_data(id))
          ..feed(_cancel(id))
          ..feed(
            after == 'message'
                ? _data(id)
                : RpcChannelFrame.encodeEndOfStream(id),
          );
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.errors, isEmpty);
    });
  }

  test('GUARD: an id reused after the cancel opens a new call', () async {
    final s = await _start();
    s.chan
      ..feed(_open(1))
      ..feed(_data(1))
      ..feed(_cancel(1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final before = s.chan.sent.length;
    s.chan
      ..feed(_open(1))
      ..feed(_data(1))
      ..feed(
        RpcChannelFrame.encodeData(
          streamId: 1,
          payload: Uint8List(0),
          endOfStream: true,
        ),
      );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final statuses = [
      for (final f in s.chan.sent.skip(before))
        RpcChannelFrame.decode(
          f,
        )?.metadata?.getHeaderValue(RpcHeaders.grpcStatus),
    ].whereType<String>();
    expect(statuses, ['0']);
    expect(s.errors, isEmpty);
  });
}
