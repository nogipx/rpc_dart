// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request the PEER made invalid -- a payload over the size limit, a second
// request on a call that carries one, bytes the request codec cannot decode
// -- is answered with its status and is not an incident on this side. It was
// logged as one, up to three ERROR records per call, so a peer repeating the
// call chose how many: measured over 200 calls, 200 to 600 records on each
// of seven shape/input pairs. The statuses on the wire do not change.

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
      handler: (r, {RpcContext? context}) async {
        if (r.value == 'crash') throw StateError('handler bug');
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 's',
      handler: (r, {RpcContext? context}) async* {
        if (r.value == 'crash') throw StateError('handler bug');
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (reqs, {RpcContext? context}) async {
        await for (final r in reqs) {
          if (r.value == 'crash') throw StateError('handler bug');
        }
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'b',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          if (r.value == 'crash') throw StateError('handler bug');
          yield r;
        }
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

typedef _Run = ({
  List<String> errors,
  List<String> warnings,
  Set<String> statuses,
});

/// [calls] calls of [method], each carrying [payload], then a half-close.
Future<_Run> _run(String method, Uint8List payload, {int calls = 10}) async {
  final controller = LogController(minLevel: RpcLogLevel.warning);
  final errors = <String>[];
  final warnings = <String>[];
  controller.stream.listen((r) {
    if (r is LogEvent && r.level == RpcLogLevel.error) errors.add(r.message);
    if (r is LogEvent && r.level == RpcLogLevel.warning) {
      warnings.add(r.message);
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
  for (var k = 0; k < calls; k++) {
    final id = 1 + 2 * k;
    chan.feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forClientRequest('Svc', method),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    chan.feed(RpcChannelFrame.encodeData(streamId: id, payload: payload));
    await Future<void>.delayed(Duration.zero);
    chan.feed(RpcChannelFrame.encodeEndOfStream(id));
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final statuses = <String>{};
  for (final f in chan.sent) {
    final s = RpcChannelFrame.decode(
      f,
    )?.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
    if (s != null) statuses.add(s);
  }
  return (errors: errors, warnings: warnings, statuses: statuses);
}

void main() {
  final one = RpcMessageFrame.encode(_codec.serialize('hi'.rpc));
  final oversized = Uint8List.fromList([0, 0x7f, 0xff, 0xff, 0xff, 1, 2, 3]);
  final twoMessages = Uint8List.fromList([...one, ...one]);
  final badCbor = RpcMessageFrame.encode(Uint8List.fromList([0xff, 0xff, 0]));
  final crash = RpcMessageFrame.encode(_codec.serialize('crash'.rpc));

  for (final method in ['u', 's', 'c', 'b']) {
    test(
      '$method: a payload over the limit is answered, not an error',
      () async {
        final r = await _run(method, oversized);
        expect(r.errors, isEmpty);
        expect(r.statuses, {'${RpcStatus.resourceExhausted}'});
      },
    );

    test('$method: an undecodable payload is answered, not an error', () async {
      final r = await _run(method, badCbor);
      expect(r.errors, isEmpty);
      expect(r.statuses, {'${RpcStatus.internal}'});
    });

    test('GUARD $method: a handler that crashes is still an error', () async {
      final r = await _run(method, crash);
      expect(r.errors, isNotEmpty);
      expect(r.statuses, {'${RpcStatus.internal}'});
    });
  }

  for (final method in ['u', 's']) {
    test('$method: a second request is answered, not an error', () async {
      final r = await _run(method, twoMessages);
      expect(r.errors, isEmpty);
      expect(r.statuses, {'${RpcStatus.internal}'});
    });
  }

  test('s: the handler producing after the answer writes no warning', () async {
    // The second request is answered INTERNAL, which closes the response
    // controller while the handler still yields for the first. Before: one
    // "Attempted to send response to closed controller" warning per call.
    final r = await _run('s', twoMessages);
    expect(r.warnings, isEmpty);
  });
}
