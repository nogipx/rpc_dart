// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream peer that sends a message AFTER its own half-close breaks
// the protocol, and dropping the message is right. But the pipeline counted
// it as accepted, the handler (already finished) never got it, and the
// request-loss alarm reported "Request messages LOST" at ERROR -- once per
// call the peer chose to send that way. Measured over 50 calls: 50 errors.
// The alarm exists for REAL loss, and false ones are what hide it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.counts) : super('Svc');

  final List<int> counts;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
        }
        counts.add(n);
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Chan implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {}

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

typedef _Run = ({List<String> records, List<int> counts});

Future<_Run> _run({required bool late, int calls = 10}) async {
  final controller = LogController(minLevel: RpcLogLevel.warning);
  final records = <String>[];
  controller.stream.listen((r) {
    if (r is LogEvent && r.level.index >= RpcLogLevel.warning.index) {
      records.add(r.message);
    }
  });
  final counts = <int>[];
  final chan = _Chan();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: false,
  );
  final responder =
      RpcResponderEndpoint(transport: transport, logger: controller)
        ..registerServiceContract(_Svc(counts))
        ..start();
  addTearDown(() async {
    await responder.close();
    await transport.close();
  });

  final message = RpcMessageFrame.encode(_codec.serialize('hi'.rpc));
  for (var k = 0; k < calls; k++) {
    final id = 1 + 2 * k;
    chan.feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forClientRequest('Svc', 'c'),
      ),
    );
    final data = RpcChannelFrame.encodeData(streamId: id, payload: message);
    final end = RpcChannelFrame.encodeData(
      streamId: id,
      payload: Uint8List(0),
      endOfStream: true,
    );
    if (late) {
      chan
        ..feed(end)
        ..feed(data);
    } else {
      chan
        ..feed(data)
        ..feed(end);
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return (records: records, counts: counts);
}

void main() {
  test('a message after the half-close is dropped without an alarm', () async {
    // WITNESS. Before: one "Request messages LOST" error per call.
    final r = await _run(late: true);
    expect(r.records, isEmpty);
    expect(r.counts, everyElement(0));
  });

  test('GUARD: a message before the half-close is delivered', () async {
    final r = await _run(late: false);
    expect(r.records, isEmpty);
    expect(r.counts, everyElement(1));
  });
}
