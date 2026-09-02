// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcStatusException carries structured `details` -- the class docstring shows
// exactly this usage -- encoded onto the wire as grpc-status-details-bin.
// Measured with a handler throwing NOT_FOUND plus an RpcErrorInfo and an
// RpcBadRequest:
//
//   unary   -> RpcStatusException(5) msg="user 42 not found" details=2
//   server  -> RpcStatusException(5) msg="user 42 not found" details=2
//   client  -> RpcStatusException(5) msg="user 42 not found" details=2
//   bidi    -> RpcStatusException(5) msg="user 42 not found" details=0
//
// BidirectionalStreamResponder.sendError had no statusDetailsBin parameter at
// all, so the responder pipeline could not pass one. Status code and message
// arrived intact, which is what made the loss silent: the error looked
// delivered, and only the machine-readable half was missing.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

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
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async => throw _boom(),
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'server',
      handler: (r, {RpcContext? context}) async* {
        throw _boom();
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'client',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {}
        throw _boom();
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (reqs, {RpcContext? context}) async* {
        throw _boom();
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Throws something that is NOT an RpcStatusException: must still map to
    // INTERNAL, with no details and no crash on the null path.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidiPlain',
      handler: (reqs, {RpcContext? context}) async* {
        throw StateError('plain failure');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidiOk',
      handler: (reqs, {RpcContext? context}) async* {
        yield 'fine'.rpc;
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

Future<Object?> _drive(_Rig rig, String shape, {String? method}) async {
  final name = method ?? shape;
  try {
    switch (shape) {
      case 'unary':
        await rig.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: name,
          request: 'a'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
      case 'server':
        await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: name,
              request: 'a'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList();
      case 'client':
        await rig.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: name,
          requestCodec: _codec,
          responseCodec: _codec,
        )(_one());
      case 'bidi':
        await rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: name,
              requests: _one(),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList();
    }
  } catch (e) {
    return e;
  }
  return null;
}

void main() {
  group('structured error details survive on every shape', () {
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
          reason: '$shape delivered ${e.details.length} of 2 detail objects',
        );

        final info = e.details.whereType<RpcErrorInfo>().single;
        expect(info.reason, 'USER_NOT_FOUND');
        expect(info.domain, 'accounts.v1');

        final bad = e.details.whereType<RpcBadRequest>().single;
        expect(bad.violations.single.field, 'id');
        expect(bad.violations.single.description, 'no such user');

        await _teardown(rig);
      });
    }
  });

  group('bidirectional error handling is otherwise unchanged', () {
    test('a non-status error still maps to INTERNAL', () async {
      // The null branch of the new statusDetailsBin argument.
      final rig = _connect();

      final thrown = await _drive(rig, 'bidi', method: 'bidiPlain');
      expect(thrown, isA<RpcStatusException>());
      final e = thrown! as RpcStatusException;
      expect(e.statusCode, RpcStatus.internal);
      expect(e.details, isEmpty);

      await _teardown(rig);
    });

    test('a successful bidi call is unaffected', () async {
      final rig = _connect();

      final got = await rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bidiOk',
            requests: _one(),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((r) => r.value)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(got, ['fine']);
      await _teardown(rig);
    });
  });
}
