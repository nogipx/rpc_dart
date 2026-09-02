// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A gRPC stream that ends without a trailer is an INCOMPLETE call. CallProcessor
// closed its response controller silently in that case, so a server-stream or
// bidirectional consumer whose connection died mid-stream saw a clean end and
// could not tell a truncated result from a complete one.
//
// Measured by tearing the transport down under four in-flight calls, one per
// shape. Before:
//
//   responder.close()   unary:Status(14) client:Status(14) server:ok bidi:ok
//   server transport    unary:Status(14) client:Status(14) server:ok bidi:ok
//
// After, all four report Status(14) = UNAVAILABLE.
//
// Why reaching onDone with the controller still OPEN means a collapse: every
// ordinary ending closes it first. A normal finish and an error trailer both
// arrive as end-of-stream and are closed by _handleResponse; a cancellation and
// a deadline are closed by the scope disposers. So an open controller here can
// only mean the stream went away mid-call.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Held open so a handler stays mid-stream until the test tears things down.
Completer<void> _hold = Completer<void>();

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'partial',
      handler: (r, {RpcContext? context}) async* {
        yield 'first'.rpc;
        await _hold.future;
        yield 'second'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'partialBidi',
      handler: (reqs, {RpcContext? context}) async* {
        yield 'first'.rpc;
        await _hold.future;
        yield 'second'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'complete',
      handler: (r, {RpcContext? context}) async* {
        yield 'a'.rpc;
        yield 'b'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'fails',
      handler: (r, {RpcContext? context}) async* {
        yield 'a'.rpc;
        throw RpcStatusException(RpcStatus.notFound, 'gone');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'mirror',
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

Stream<RpcString> _one() {
  final c = StreamController<RpcString>();
  c.add('a'.rpc);
  unawaited(c.close());
  return c.stream;
}

Matcher get _unavailable => isA<RpcStatusException>().having(
  (e) => e.statusCode,
  'statusCode',
  RpcStatus.unavailable,
);

void main() {
  setUp(() => _hold = Completer<void>());
  tearDown(() {
    if (!_hold.isCompleted) _hold.complete();
  });

  group('a collapsed stream is reported, not silently truncated', () {
    test('server stream, transport dies mid-stream', () async {
      final rig = _connect();
      final got = <String>[];
      final done = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'partial',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .forEach((r) => got.add(r.value));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(got, ['first'], reason: 'the first item should have arrived');
      await rig.server.close();

      await expectLater(
        done.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the stream never ended'),
        ),
        throwsA(_unavailable),
      );

      await rig.caller.close();
      await rig.client.close();
    });

    test('bidirectional stream, transport dies mid-stream', () async {
      final rig = _connect();
      final got = <String>[];
      final done = rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'partialBidi',
            requests: _one(),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .forEach((r) => got.add(r.value));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(got, ['first']);
      await rig.server.close();

      await expectLater(
        done.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the stream never ended'),
        ),
        throwsA(_unavailable),
      );

      await rig.caller.close();
      await rig.client.close();
    });

    test('the responder shutting down also reports it', () async {
      final rig = _connect();
      final done = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'partial',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await rig.responder.close();

      await expectLater(
        done.timeout(const Duration(seconds: 5)),
        throwsA(_unavailable),
      );

      await rig.caller.close();
      await rig.client.close();
      await rig.server.close();
    });
  });

  group('every ordinary ending is unaffected', () {
    test('a stream that completes normally', () async {
      final rig = _connect();
      expect(
        await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'complete',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .map((r) => r.value)
            .toList()
            .timeout(const Duration(seconds: 5)),
        ['a', 'b'],
      );
      await _teardown(rig);
    });

    test('a handler error keeps its own status', () async {
      // NOT_FOUND must not be overwritten by UNAVAILABLE.
      final rig = _connect();
      await expectLater(
        rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'fails',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList()
            .timeout(const Duration(seconds: 5)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.notFound,
          ),
        ),
      );
      await _teardown(rig);
    });

    test('a cancelled stream reports cancellation', () async {
      final rig = _connect();
      final token = RpcCancellationToken();
      final done = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'partial',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withCancellation(token),
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 150));
      token.cancel('user quit');

      await expectLater(
        done.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcCancelledException>()),
      );
      await _teardown(rig);
    });

    test('an expired deadline still reports the deadline', () async {
      // The deadline branch takes precedence over the collapse branch.
      final rig = _connect();
      await expectLater(
        rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'partial',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: RpcContext.withTimeout(
                const Duration(milliseconds: 300),
              ),
            )
            .toList()
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
      await _teardown(rig);
    });

    test('a bidi stream the client ends normally', () async {
      final rig = _connect();
      expect(
        await rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'mirror',
              requests: _one(),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .map((r) => r.value)
            .toList()
            .timeout(const Duration(seconds: 5)),
        ['a'],
      );
      await _teardown(rig);
    });

    test('repeated normal calls never report a collapse', () async {
      // The nightmare: a false positive on the happy path, under repetition.
      final rig = _connect();
      for (var i = 0; i < 30; i++) {
        expect(
          await rig.caller
              .serverStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'complete',
                request: 'x'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .map((r) => r.value)
              .toList(),
          ['a', 'b'],
        );
      }
      await _teardown(rig);
    });
  });
}
