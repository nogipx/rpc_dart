// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ClientStreamCaller.call() was
//
//   await for (final request in requests) { await send(request); }
//   return await finishSending();
//
// A deadline and a cancellation are delivered on the RESPONSE path, which that
// loop never reached. So a client-stream call whose producer had not closed
// yet ignored both entirely -- measured with the request stream left open:
//
//   requests closed, no deadline      -> returned after 37ms
//   requests OPEN, deadline 1s        -> HUNG past 4s
//   requests OPEN, cancelled at 500ms -> HUNG past 4s
//
// finishSending()'s docstring says the wait "is bounded by the context deadline
// when one is set". True of that line, and false of the call as a whole: the
// bound sat behind a loop that could never finish.
//
// call() now races the request drain against the call failing, so a stalled
// producer no longer outlives the deadline: 1004ms and 503ms respectively.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      handler: (requests, {RpcContext? context}) async {
        final seen = <String>[];
        await for (final r in requests) {
          seen.add(r.value);
        }
        return seen.join(',').rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<void> _teardown(_Rig r, StreamController<RpcString> requests) async {
  if (!requests.isClosed) await requests.close();
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

Future<String> _call(_Rig rig, Stream<RpcString> requests, RpcContext? ctx) {
  return rig.caller
      .clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'collect',
        requestCodec: _codec,
        responseCodec: _codec,
        context: ctx,
      )(requests)
      .then((r) => r.value);
}

void main() {
  test('a deadline fires while the request stream is still open', () async {
    final rig = _connect();
    // Deliberately never closed: the producer has stalled.
    final requests = StreamController<RpcString>();
    requests.add('a'.rpc);

    final sw = Stopwatch()..start();
    await expectLater(
      _call(
        rig,
        requests.stream,
        RpcContext.withTimeout(const Duration(milliseconds: 600)),
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the deadline never fired on a stalled producer'),
      ),
      throwsA(isA<RpcDeadlineExceededException>()),
    );
    sw.stop();

    expect(
      sw.elapsedMilliseconds,
      lessThan(3000),
      reason:
          'the call outlived its deadline by too much '
          '(${sw.elapsedMilliseconds}ms for a 600ms deadline)',
    );

    await _teardown(rig, requests);
  });

  test('cancellation fires while the request stream is still open', () async {
    final rig = _connect();
    final requests = StreamController<RpcString>();
    requests.add('a'.rpc);

    final token = RpcCancellationToken();
    Timer(const Duration(milliseconds: 300), () => token.cancel('user quit'));

    await expectLater(
      _call(rig, requests.stream, RpcContext.withCancellation(token)).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('cancellation never reached a stalled producer'),
      ),
      throwsA(isA<RpcCancelledException>()),
    );

    await _teardown(rig, requests);
  });

  group('the ordinary path is unchanged', () {
    test('every request is delivered, in order', () async {
      final rig = _connect();
      final requests = StreamController<RpcString>();
      for (final v in ['a', 'b', 'c', 'd', 'e']) {
        requests.add(v.rpc);
      }
      unawaited(requests.close());

      expect(
        await _call(
          rig,
          requests.stream,
          null,
        ).timeout(const Duration(seconds: 5)),
        'a,b,c,d,e',
        reason: 'requests were dropped or reordered',
      );

      await _teardown(rig, requests);
    });

    test('a request-stream error surfaces to the caller', () async {
      final rig = _connect();
      final requests = StreamController<RpcString>();
      requests.add('a'.rpc);
      requests.addError(StateError('producer blew up'));

      await expectLater(
        _call(rig, requests.stream, null).timeout(const Duration(seconds: 5)),
        throwsA(isA<StateError>()),
      );

      await _teardown(rig, requests);
    });

    test('a deadline that never expires does not interfere', () async {
      final rig = _connect();
      final requests = StreamController<RpcString>();
      requests.add('x'.rpc);
      unawaited(requests.close());

      expect(
        await _call(
          rig,
          requests.stream,
          RpcContext.withTimeout(const Duration(seconds: 30)),
        ).timeout(const Duration(seconds: 5)),
        'x',
      );

      await _teardown(rig, requests);
    });
  });
}
