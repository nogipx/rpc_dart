// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An `async` callback handed to `Stream.listen` has nothing awaiting it, so
// whatever it throws goes to `Zone.current.handleUncaughtError` — and a Dart
// server with no zone handler exits 255 on that. The call shapes have eleven
// such callbacks; five carried a try/catch and six did not, and the six were
// each one line from a crash.
//
// Both cases below are ORDINARY, not hostile: a producer that has not yet
// noticed a cancellation, and a handler that fails while the peer is going
// away. Neither involves a misbehaving peer.
//
// Measured across the four shapes before the guards (probe
// `shape_edge_matrix.dart`): an ordinary call, a handler failing part-way, the
// transport dying mid-call and a consumer walking away all behaved identically
// on all four. Only the late request reached the zone.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
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

/// Runs [body] with a zone handler and reports what reached it.
Future<List<Object>> _collectingUncaught(Future<void> Function() body) async {
  final uncaught = <Object>[];
  final finished = Completer<void>();

  unawaited(
    runZonedGuarded(
      () async {
        await body();
        if (!finished.isCompleted) finished.complete();
      },
      (Object error, StackTrace stack) {
        uncaught.add(error);
        if (!finished.isCompleted) finished.complete();
      },
    ),
  );

  await finished.future;
  // The throw can land a turn after the body returns.
  await Future<void>.delayed(const Duration(milliseconds: 150));
  return uncaught;
}

void main() {
  group('a late request on a cancelled bidi call', () {
    test('WITNESS: requestSink does not throw into the zone', () async {
      final uncaught = await _collectingUncaught(() async {
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server);
        responder.registerServiceContract(_Contract());
        responder.start();

        final token = RpcCancellationToken();
        final caller = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: client,
          serviceName: 'Svc',
          methodName: 'echo',
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withCancellation(token),
        );
        caller.responses.listen((_) {}, onError: (Object _) {});

        final sink = caller.requestSink;
        sink.add('a'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        // The consumer leaves. The producer has not noticed and pushes once
        // more — the sink is still open, so this is a legal call.
        token.cancel('consumer left');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        sink.add('b'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 150));

        await caller.close().catchError((_) {});
        await responder.close();
        await client.close();
        await server.close();
      });

      expect(
        uncaught,
        isEmpty,
        reason:
            'requestSink let a send failure reach the zone. In a server '
            'process that is exit(255), triggered by nothing worse than a '
            'cancelled call whose producer pushed once more: '
            '${uncaught.isEmpty ? '' : uncaught.first}',
      );
    });

    test('GUARD: requestSink still delivers and half-closes', () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      responder.registerServiceContract(_Contract());
      responder.start();

      final caller = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'Svc',
        methodName: 'echo',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      final seen = <String>[];
      final done = Completer<void>();
      caller.payloadResponses.listen((r) {
        seen.add(r.value);
        if (seen.length == 2 && !done.isCompleted) done.complete();
      }, onError: (Object _) {});

      caller.requestSink.add('a'.rpc);
      caller.requestSink.add('b'.rpc);
      await caller.requestSink.close();

      await done.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('requestSink stopped delivering: got $seen'),
      );
      expect(seen, ['a', 'b']);

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });
  });

  group('a unary handler that fails while the peer is going away', () {
    test('WITNESS: the failed error trailer does not reach the zone', () async {
      final uncaught = await _collectingUncaught(() async {
        final (client, server) = RpcChannelTransport.pair();

        final unary = UnaryResponder<RpcString, RpcString>(
          id: 0,
          transport: server,
          serviceName: 'Svc',
          methodName: 'boom',
          requestCodec: _codec,
          responseCodec: _codec,
          handler: (_) async {
            // Fail only AFTER the wire is gone, which is the ordinary order:
            // the peer disconnects, the handler's next await throws.
            await server.close();
            throw StateError('handler died');
          },
        );

        // Open the call the way a caller does, then feed the request frame.
        final caller = UnaryCaller<RpcString, RpcString>(
          transport: client,
          serviceName: 'Svc',
          methodName: 'boom',
          requestCodec: _codec,
          responseCodec: _codec,
        );
        unawaited(
          caller
              .call('a'.rpc, timeout: const Duration(milliseconds: 400))
              .catchError((Object _) => 'x'.rpc),
        );

        await Future<void>.delayed(const Duration(milliseconds: 500));
        await unary.close().catchError((_) {});
        await caller.close().catchError((_) {});
        await client.close();
      });

      expect(
        uncaught,
        isEmpty,
        reason:
            'the unary responder let its own error-trailer send reach the '
            'zone. The trailer cannot be delivered because the transport is '
            'already closed, which is exactly when a handler fails: '
            '${uncaught.isEmpty ? '' : uncaught.first}',
      );
    });

    test('GUARD: an ordinary unary call still answers', () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      final caller = RpcCallerEndpoint(transport: client);
      responder.registerServiceContract(_EchoContract());
      responder.start();

      final result = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'hello'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(result.value, 'hello');

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });
  });
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
