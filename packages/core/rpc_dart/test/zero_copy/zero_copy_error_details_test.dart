// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Zero-copy is a parallel implementation of every call shape -- its own
// responder branches, direct object passing, no serialization -- and is far
// less exercised than the codec path. Running the error-parity sweep against it
// found the caller-side mirror of a bug already fixed on the responder side.
//
// A handler throwing RpcStatusException with structured `details`, over
// RpcInMemoryTransport:
//
//   unary   -> Status(5) "missing" details=0     <-- dropped
//   server  -> Status(5) "missing" details=1
//   client  -> Status(5) "missing" details=1
//   bidi    -> Status(5) "missing" details=1
//
// _executeUnaryCall -- the zero-copy unary caller -- built its exception with
// `RpcStatusException(status, message)` instead of `fromTrailer(..., detailsBin:)`.
// The responder had already put the details on the wire and every other shape
// read them back; this one path discarded them. Status and message arrived
// intact, which is what made the loss silent.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A plain object: never serialized on this path.
final class Msg {
  const Msg(this.v);
  final String v;
}

RpcStatusException _boom() => RpcStatusException(
  RpcStatus.notFound,
  'user 42 not found',
  details: [
    RpcErrorInfo(reason: 'USER_NOT_FOUND', domain: 'accounts.v1'),
    RpcBadRequest([
      const RpcFieldViolation(field: 'id', description: 'no such user'),
    ]),
  ],
);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // No codecs -> zero-copy registrations.
    addUnaryMethod<Msg, Msg>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async => throw _boom(),
    );
    addServerStreamMethod<Msg, Msg>(
      methodName: 'server',
      handler: (r, {RpcContext? context}) async* {
        throw _boom();
      },
    );
    addClientStreamMethod<Msg, Msg>(
      methodName: 'client',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {}
        throw _boom();
      },
    );
    addBidirectionalMethod<Msg, Msg>(
      methodName: 'bidi',
      handler: (reqs, {RpcContext? context}) async* {
        throw _boom();
      },
    );
    addUnaryMethod<Msg, Msg>(
      methodName: 'plain',
      handler: (r, {RpcContext? context}) async =>
          throw StateError('no status here'),
    );
    addUnaryMethod<Msg, Msg>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => Msg('e:${r.v}'),
    );
  }
}

typedef _Rig = ({
  IRpcTransport client,
  IRpcTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect() {
  final (client, server) = RpcInMemoryTransport.pair();
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

Stream<Msg> _reqs() {
  final c = StreamController<Msg>();
  c.add(const Msg('a'));
  unawaited(c.close());
  return c.stream;
}

Future<Object?> _drive(_Rig rig, String shape) async {
  try {
    switch (shape) {
      case 'unary':
        await rig.caller.unaryRequest<Msg, Msg>(
          serviceName: 'Svc',
          methodName: 'unary',
          request: const Msg('a'),
        );
      case 'server':
        await rig.caller
            .serverStream<Msg, Msg>(
              serviceName: 'Svc',
              methodName: 'server',
              request: const Msg('a'),
            )
            .toList();
      case 'client':
        await rig.caller.clientStream<Msg, Msg>(
          serviceName: 'Svc',
          methodName: 'client',
        )(_reqs());
      case 'bidi':
        await rig.caller
            .bidirectionalStream<Msg, Msg>(
              serviceName: 'Svc',
              methodName: 'bidi',
              requests: _reqs(),
            )
            .toList();
    }
  } catch (e) {
    return e;
  }
  return null;
}

void main() {
  group('zero-copy carries structured error details on every shape', () {
    for (final shape in ['unary', 'server', 'client', 'bidi']) {
      test(shape, () async {
        final rig = _connect();

        final thrown = await _drive(rig, shape);
        expect(thrown, isA<RpcStatusException>());

        final e = thrown! as RpcStatusException;
        expect(e.statusCode, RpcStatus.notFound);
        expect(e.message, 'user 42 not found');
        expect(
          e.details,
          hasLength(2),
          reason: 'zero-copy $shape delivered ${e.details.length} of 2 details',
        );
        expect(
          e.details.whereType<RpcErrorInfo>().single.reason,
          'USER_NOT_FOUND',
        );
        expect(
          e.details.whereType<RpcBadRequest>().single.violations.single.field,
          'id',
        );

        await _teardown(rig);
      });
    }
  });

  group('unchanged behaviour', () {
    test('a non-status error still maps to INTERNAL with no details', () async {
      // The null-detailsBin branch.
      final rig = _connect();
      Object? thrown;
      try {
        await rig.caller.unaryRequest<Msg, Msg>(
          serviceName: 'Svc',
          methodName: 'plain',
          request: const Msg('a'),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<RpcStatusException>());
      expect((thrown! as RpcStatusException).statusCode, RpcStatus.internal);
      expect((thrown as RpcStatusException).details, isEmpty);
      await _teardown(rig);
    });

    test('a successful zero-copy call passes the object through', () async {
      final rig = _connect();
      final r = await rig.caller.unaryRequest<Msg, Msg>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: const Msg('hi'),
      );
      expect(r.v, 'e:hi');
      await _teardown(rig);
    });

    test('repeated calls leave no per-call state behind', () async {
      final rig = _connect();
      for (var i = 0; i < 20; i++) {
        await rig.caller.unaryRequest<Msg, Msg>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: const Msg('x'),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.caller.collectEndpointMetrics()['pendingRequests'], 0);
      expect(rig.responder.collectEndpointMetrics()['openStreams'], 0);
      await _teardown(rig);
    });
  });
}
