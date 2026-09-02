// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Registering the same method name twice on a contract was a plain map
// assignment, so the second silently replaced the first and the LAST one won:
//
//   same name, same shape      -> call answered by the SECOND handler
//   same name, different shape -> a UNARY call answered by a server-stream
//                                 handler, with nothing logged
//   codec + zero-copy          -> RpcException (the registry already caught it)
//
// The second row is the dangerous one: the method's SHAPE changes underneath
// the caller. The registry already refused the codec/zero-copy version of the
// same collision, so refusing the same-map case is the consistent behaviour
// rather than a new one. It is a construction-time programming error, raised
// where the duplicate is written, and unreachable from peer input.
//
// Refusing duplicates exposed a second problem. `setup()` is public and calling
// it before registering reads as natural -- the isolate and websocket transport
// tests both do it -- and registerServiceContract then ran it a SECOND time,
// re-registering every method. That was harmless only because duplicates were
// silently swallowed. Registration now runs setup() only when nothing has been
// declared yet, which also makes registering one contract instance on two
// endpoints work.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SameShape extends RpcResponderContract {
  _SameShape() : super('Same');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'm',
      handler: (r, {RpcContext? context}) async => 'first'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'm',
      handler: (r, {RpcContext? context}) async => 'second'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _DifferentShape extends RpcResponderContract {
  _DifferentShape() : super('Diff');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'm',
      handler: (r, {RpcContext? context}) async => 'unary'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'm',
      handler: (r, {RpcContext? context}) async* {
        yield 'stream'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _MixedMode extends RpcResponderContract {
  _MixedMode() : super('Mixed');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'm',
      handler: (r, {RpcContext? context}) async => 'codec'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    // No codecs -> zero-copy, so it lands in the other map.
    addUnaryMethod<Object, Object>(
      methodName: 'm',
      handler: (r, {RpcContext? context}) async => 'zeroCopy',
    );
  }
}

final class _Ordinary extends RpcResponderContract {
  _Ordinary() : super('Ok');

  int setupRuns = 0;

  @override
  void setup() {
    setupRuns++;
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'a',
      handler: (r, {RpcContext? context}) async => 'a:${r.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'b',
      handler: (r, {RpcContext? context}) async* {
        yield 'b'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Matcher get _duplicateError => isA<RpcException>().having(
  (e) => e.toString(),
  'message',
  contains('already registered'),
);

void main() {
  group('a duplicate method name is refused', () {
    test('same shape twice', () {
      expect(() => _SameShape().setup(), throwsA(_duplicateError));
    });

    test('different shapes, which silently changed the shape', () {
      expect(() => _DifferentShape().setup(), throwsA(_duplicateError));
    });

    test('codec and zero-copy, across the two maps', () {
      expect(() => _MixedMode().setup(), throwsA(_duplicateError));
    });

    test('the failure names the method', () {
      Object? thrown;
      try {
        _SameShape().setup();
      } catch (e) {
        thrown = e;
      }
      expect(thrown.toString(), contains('Same.m'));
    });
  });

  group('ordinary registration is unaffected', () {
    test('setup runs once when the caller does not call it', () async {
      final contract = _Ordinary();
      final (client, server) = RpcChannelTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(contract)
        ..start();

      expect(contract.setupRuns, 1);
      expect(
        (await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Ok',
          methodName: 'a',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value,
        'a:x',
      );

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });

    test('calling setup() first does not re-run it', () async {
      // What the isolate and websocket transport tests do.
      final contract = _Ordinary()..setup();
      expect(contract.setupRuns, 1);

      final (client, server) = RpcChannelTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(contract)
        ..start();

      expect(
        contract.setupRuns,
        1,
        reason: 'registration must not run setup a second time',
      );
      expect(
        (await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Ok',
          methodName: 'a',
          request: 'y'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value,
        'a:y',
      );

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });

    test('one contract instance serves two endpoints', () async {
      final contract = _Ordinary();
      final rigs =
          <
            (
              RpcChannelTransport,
              RpcChannelTransport,
              RpcCallerEndpoint,
              RpcResponderEndpoint,
            )
          >[];
      for (var i = 0; i < 2; i++) {
        final (client, server) = RpcChannelTransport.pair();
        final caller = RpcCallerEndpoint(transport: client);
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(contract)
          ..start();
        rigs.add((client, server, caller, responder));
      }
      expect(contract.setupRuns, 1);

      for (final rig in rigs) {
        expect(
          (await rig.$3.unaryRequest<RpcString, RpcString>(
            serviceName: 'Ok',
            methodName: 'a',
            request: 'z'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )).value,
          'a:z',
        );
      }

      for (final rig in rigs) {
        await rig.$3.close();
        await rig.$4.close();
        await rig.$1.close();
        await rig.$2.close();
      }
    });

    test('distinct names in one contract still register', () {
      final contract = _Ordinary()..setup();
      expect(contract.methods.keys.toList()..sort(), ['a', 'b']);
    });
  });
}
