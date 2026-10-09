// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream handler that finished after the peer cancelled the call
// still sent its response into the torn-down processor, which logged a
// WARNING ("Attempted to send response on inactive processor") per call. The
// peer chose how many by cancelling. Unary, server-stream and bidi already
// dropped a late answer silently. Measured over 100 cancelled calls on one
// connection: client-stream 100 records, the other three 0.

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
        // Ignores its token, as most handlers do.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Chan implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  final sent = StreamController<Uint8List>.broadcast();
  final all = <Uint8List>[];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    all.add(data);
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

typedef _Run = ({List<String> records, List<String?> statuses});

Future<_Run> _run({required bool cancel, int calls = 10}) async {
  final controller = LogController(minLevel: RpcLogLevel.warning);
  final records = <String>[];
  controller.stream.listen((r) {
    if (r is LogEvent && r.level.index >= RpcLogLevel.warning.index) {
      records.add(r.message);
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

  final full = RpcMessageFrame.encode(_codec.serialize('hi'.rpc));
  for (var k = 0; k < calls; k++) {
    final id = 1 + 2 * k;
    chan
      ..feed(
        RpcChannelFrame.encodeMetadata(
          streamId: id,
          metadata: RpcMetadata.forClientRequest('Svc', 'c'),
        ),
      )
      ..feed(RpcChannelFrame.encodeData(streamId: id, payload: full));
    // Let the handler start before the peer acts.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    chan.feed(
      cancel
          ? RpcChannelFrame.encodeMetadata(
              streamId: id,
              metadata: RpcMetadata([
                RpcHeader(RpcHeaders.xClientCancelled, 'true'),
              ]),
            )
          : RpcChannelFrame.encodeEndOfStream(id),
    );
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final statuses = <String?>[];
  for (var k = 0; k < calls; k++) {
    final id = 1 + 2 * k;
    String? status;
    for (final f in chan.all) {
      final d = RpcChannelFrame.decode(f);
      if (d?.streamId == id) {
        status ??= d?.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      }
    }
    statuses.add(status);
  }
  return (records: records, statuses: statuses);
}

void main() {
  test('a client stream the peer cancelled writes no log line', () async {
    // WITNESS. Before: one "Attempted to send response on inactive
    // processor" per call.
    final r = await _run(cancel: true);
    expect(r.records, isEmpty);
    expect(
      r.statuses.where((s) => s == '0'),
      isEmpty,
      reason: 'a cancelled call must not be answered OK',
    );
  });

  test('GUARD: a client stream nobody cancelled is still answered', () async {
    final r = await _run(cancel: false);
    expect(r.records, isEmpty);
    expect(r.statuses, everyElement('0'));
  });
}
