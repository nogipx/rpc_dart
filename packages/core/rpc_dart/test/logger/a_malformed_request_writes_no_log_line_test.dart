// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A malformed request is the PEER's error: it is answered INVALID_ARGUMENT and
// is not a server incident. Client-stream and bidi answer it without a log
// line; unary wrote a WARNING per call and server-stream an ERROR per call, so
// a peer repeating one malformed call chose how many records the server wrote.
// Counted over 200 calls on one connection: 200 each, against 0 for the other
// two shapes.

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
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 's',
      handler: (r, {RpcContext? context}) async* {
        yield r;
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

typedef _Run = ({List<String> records, List<String?> statuses});

/// [calls] calls of [method] on one connection, each carrying [payload] (or no
/// DATA frame when null) and then a half-close.
Future<_Run> _run(String method, Uint8List? payload, {int calls = 20}) async {
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

  for (var k = 0; k < calls; k++) {
    final id = 1 + 2 * k;
    chan.feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forClientRequest('Svc', method),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    if (payload != null) {
      chan.feed(RpcChannelFrame.encodeData(streamId: id, payload: payload));
      await Future<void>.delayed(Duration.zero);
    }
    chan.feed(RpcChannelFrame.encodeEndOfStream(id));
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final statuses = <String?>[];
  for (var k = 0; k < calls; k++) {
    final id = 1 + 2 * k;
    String? status;
    for (final f in chan.sent) {
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
  final full = RpcMessageFrame.encode(_codec.serialize('hi'.rpc));
  final truncated = Uint8List.sublistView(full, 0, 5);
  final invalid = '${RpcStatus.invalidArgument}';

  test('unary: a request cut mid-frame writes no log line', () async {
    // WITNESS. Before: 20 warnings, "Client half-closed mid-frame".
    final r = await _run('u', truncated);
    expect(r.records, isEmpty);
    expect(r.statuses, everyElement(invalid));
  });

  test('unary: an empty payload frame writes no log line', () async {
    final r = await _run('u', Uint8List(0));
    expect(r.records, isEmpty);
    expect(r.statuses, everyElement(invalid));
  });

  test('unary: a bare half-close writes no log line', () async {
    final r = await _run('u', null);
    expect(r.records, isEmpty);
    expect(r.statuses, everyElement(invalid));
  });

  test('server stream: a request cut mid-frame writes no log line', () async {
    // WITNESS. Before: 20 errors, "Error in request stream".
    final r = await _run('s', truncated);
    expect(r.records, isEmpty);
    expect(r.statuses, everyElement(invalid));
  });

  test('GUARD: a valid call still succeeds and writes nothing', () async {
    final r = await _run('u', full);
    expect(r.records, isEmpty);
    expect(r.statuses, everyElement('0'));
  });

  test(
    'GUARD: a server-side fault in the request stream is still logged',
    () async {
      // A caller with codecs against a zero-copy server stream: the processor
      // reports a transfer-mode mismatch, status 13, which is a fault.
      final controller = LogController(minLevel: RpcLogLevel.warning);
      final errors = <String>[];
      controller.stream.listen((r) {
        if (r is LogEvent && r.level == RpcLogLevel.error) {
          errors.add(r.message);
        }
      });
      final (client, server) = RpcChannelTransport.memoryPair();
      final responder =
          RpcResponderEndpoint(transport: server, logger: controller)
            ..registerServiceContract(_ZeroCopySvc())
            ..start();
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      await expectLater(
        caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Zc',
              methodName: 's',
              request: 'hi'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .drain<void>()
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<RpcStatusException>()),
      );
      expect(errors, contains(startsWith('Error in request stream')));
    },
  );
}

final class _ZeroCopySvc extends RpcResponderContract {
  _ZeroCopySvc() : super('Zc', dataTransferMode: RpcDataTransferMode.zeroCopy);

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 's',
      handler: (r, {RpcContext? context}) async* {
        yield r;
      },
    );
  }
}
