// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-streaming RPC may legitimately carry ZERO messages, and gRPC expects
// that to open the call anyway: HEADERS, then end-of-stream. The server's
// handler receives an empty request stream and returns its response.
//
// CallProcessor sent the initial metadata only from _transmitRequest, which
// runs from send(). A call that sent no request therefore never announced
// itself: no method path reached the responder, no handler ran, and the caller
// waited out its own timeout against a server that had no idea the call
// existed.
//
// NOT covered here: a BIDIRECTIONAL call that sends nothing. That fails for a
// different reason -- the responder's _handleEndOfStream explicitly rejects a
// stream that closed without a payload ('Request stream closed without payload
// for ...', INVALID_ARGUMENT). Correct for unary and server-stream, which
// require exactly one request message; wrong for bidi, where zero is legal.
// Untangling that guard is a separate change.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Set when a handler actually runs, proving the call reached the server.
final List<String> _handlerRuns = [];

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      handler: (requests, {RpcContext? context}) async {
        _handlerRuns.add('collect');
        final seen = <String>[];
        await for (final r in requests) {
          seen.add(r.value);
        }
        return 'got:${seen.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'greet',
      handler: (requests, {RpcContext? context}) async* {
        _handlerRuns.add('greet');
        // Emits before reading anything: a server-push conversation.
        yield 'hello'.rpc;
        await for (final r in requests) {
          yield r;
        }
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

Future<void> _teardown(_Rig r) async {
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

void main() {
  setUp(_handlerRuns.clear);

  test('a client stream with no messages reaches the server', () async {
    final rig = _connect();
    final requests = StreamController<RpcString>();
    unawaited(requests.close()); // empty, and closed

    final result = await rig.caller
        .clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'collect',
          requestCodec: _codec,
          responseCodec: _codec,
        )(requests.stream)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('an empty client stream never reached the server'),
        );

    expect(result.value, 'got:0');
    expect(_handlerRuns, ['collect'], reason: 'the handler never ran');
    await _teardown(rig);
  });

  group('non-empty calls are unchanged', () {
    test('the metadata is not sent twice', () async {
      // If finishSending queued a second initial-metadata frame, the responder
      // would see a duplicate open for the same stream.
      final rig = _connect();
      final requests = StreamController<RpcString>();
      requests.add('a'.rpc);
      requests.add('b'.rpc);
      unawaited(requests.close());

      final result = await rig.caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'collect',
            requestCodec: _codec,
            responseCodec: _codec,
          )(requests.stream)
          .timeout(const Duration(seconds: 5));

      expect(result.value, 'got:2');
      expect(
        _handlerRuns,
        ['collect'],
        reason: 'the handler ran more than once -- duplicate call open',
      );
      await _teardown(rig);
    });

    test('a bidi call that does send still works', () async {
      final rig = _connect();
      final requests = StreamController<RpcString>();
      requests.add('x'.rpc);
      unawaited(requests.close());

      final got = await rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'greet',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((r) => r.value)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(got, ['hello', 'x']);
      expect(_handlerRuns, ['greet']);
      await _teardown(rig);
    });
  });
}
