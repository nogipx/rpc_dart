// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The third implementation of the job rounds 370 and 371 fixed on the two
// sinks: the endpoint's own `_pumpBidirectionalResponses`. It relays the
// handler's stream through a controller so teardown can cancel it, and never
// forwarded the relay's pause — so the `await for` that drives it paused the
// relay while a send was in flight and the handler kept allocating regardless.
//
// This is the path an ORDINARY application takes: an async* bidi handler
// registered on a contract. The sinks are reachable only on the caller and
// responder classes directly.
//
// Measured against a consumer that does not read, a 1 MB window and 16 KiB
// messages: 2000 of 2000 produced (31.3 MB), against 68 for the server-stream
// sibling, whose relay does forward pause.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _offered = 2000;
const int _payload = 16 * 1024;

/// Generous against the 1 MB window (68 messages there), far below the 2000 an
/// unbounded pull reaches.
const int _bound = 300;

int produced = 0;

Stream<RpcString> _fire() async* {
  final body = 'x' * _payload;
  for (var i = 0; i < _offered; i++) {
    produced = i + 1;
    yield body.rpc;
  }
}

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'fire',
      handler: (reqs, {RpcContext? context}) => _fire(),
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  setUp(() => produced = 0);

  test('WITNESS: the bidi pump does not drain its handler', () async {
    final (client, server) = RpcChannelTransport.pair(
      policy: const RpcSecurityPolicy(flowControlWindowBytes: 1024 * 1024),
    );
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();

    final sub = caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'fire',
          requests: StreamController<RpcString>().stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});
    sub.pause();

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline) && produced <= _bound) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      produced,
      lessThanOrEqualTo(_bound),
      reason:
          'the pump pulled $produced of $_offered messages '
          '(${(produced * _payload / (1024 * 1024)).toStringAsFixed(1)} MB) '
          'out of the handler while the consumer was not reading. '
          '_pumpBidirectionalResponses must forward its relay pause to the '
          'handler subscription, as ServerStreamResponder does',
    );

    sub.resume();
    await sub.cancel();
    await caller.close().catchError((_) {});
    await responder.close().catchError((_) {});
    await client.close();
    await server.close();
  });

  test('GUARD: a bidi call still delivers everything, in order', () async {
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();

    const total = 40;
    Stream<RpcString> requests() async* {
      for (var i = 0; i < total; i++) {
        yield '$i'.rpc;
      }
    }

    final got = <String>[];
    await for (final r in caller.bidirectionalStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      requests: requests(),
      requestCodec: _codec,
      responseCodec: _codec,
    )) {
      got.add(r.value);
    }

    expect(got, [for (var i = 0; i < total; i++) '$i']);

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
