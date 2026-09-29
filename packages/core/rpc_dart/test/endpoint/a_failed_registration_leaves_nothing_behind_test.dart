// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `registerContract` inserted the contract, then ran `setup()`, then validated
// each method key. Everything that can throw ran AFTER the insert, so a failed
// registration was half applied — and the obvious recovery (catch, fix the
// contract, register again) was refused with "already registered".
//
// `setup()` and every key check now run into a local map before any field is
// touched, and the contract and its methods are committed in one step at the end.
//
// Two failure routes reach this and they are independent: `setup()` throwing needs
// nothing else to be wrong, while a colliding method key needs the dotted-key
// ambiguity that `a_method_name_may_not_contain_a_dot_test.dart` is about.
//
// The measurements are in `.claude/loop/rounds/503`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Its own `setup()` throws halfway: the author listed a method name twice, which
/// the contract's `_rejectDuplicate` refuses. Needs nothing else to be wrong.
final class _SetupThrows extends RpcResponderContract {
  _SetupThrows() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'first',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok'.rpc,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'first',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok2'.rpc,
    );
  }
}

/// The recovery attempt. Its method name is unlike anything the failing contracts
/// declare, so the state says unambiguously whose registration is live.
final class _Fine extends RpcResponderContract {
  _Fine(super.serviceName);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'recovered',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'answered'.rpc,
    );
  }
}

/// `ok` registers, then `c` collides with `a`'s dotted method `b.c` — both make
/// the key `a.b.c`. Insertion order is iteration order, so the throw lands with
/// one method already reserved.
final class _CollidesOnItsSecondMethod extends RpcResponderContract {
  _CollidesOnItsSecondMethod() : super('a.b');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ok',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok'.rpc,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'c',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'c'.rpc,
    );
  }
}

final class _ServiceAWithDottedMethod extends RpcResponderContract {
  _ServiceAWithDottedMethod() : super('a');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'b.c',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'from a/b.c'.rpc,
    );
  }
}

void main() {
  group('WITNESS: a registration that throws changes nothing', () {
    test('setup() throwing leaves no contract and no methods', () async {
      final (_, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(responder.close);

      expect(
        () => responder.registerServiceContract(_SetupThrows()),
        throwsA(isA<RpcStatusException>()),
      );

      expect(
        responder.registeredContracts.keys,
        isEmpty,
        reason:
            'the contract was inserted before setup() ran, so a setup() that '
            'throws left a service registered with no methods at all',
      );
      expect(responder.registeredMethodBindings.keys, isEmpty);
    });

    test('a colliding method key leaves the earlier methods out too', () async {
      final (_, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(responder.close);
      responder.registerServiceContract(_ServiceAWithDottedMethod());

      expect(
        () => responder.registerServiceContract(_CollidesOnItsSecondMethod()),
        throwsA(isA<RpcStatusException>()),
      );

      expect(
        responder.registeredContracts.keys,
        ['a'],
        reason: 'a.b must not be registered when its second method was refused',
      );
      expect(
        responder.registeredMethodBindings.keys,
        ['a.b.c'],
        reason:
            'a.b.ok was reserved before the collision was found; committing it '
            'left half a contract serving requests',
      );
    });

    test('the obvious recovery works after either failure', () async {
      for (final failing in <RpcResponderContract Function()>[
        _SetupThrows.new,
        _CollidesOnItsSecondMethod.new,
      ]) {
        final (_, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server);
        responder.registerServiceContract(_ServiceAWithDottedMethod());
        final contract = failing();
        try {
          responder.registerServiceContract(contract);
        } on RpcStatusException {
          // the author now fixes the contract and registers again
        }

        expect(
          () => responder.registerServiceContract(_Fine(contract.serviceName)),
          returnsNormally,
          reason:
              'catching the error and registering a corrected contract is the '
              'only recovery there is, and a half-applied registration refused '
              'it with "already registered"',
        );
        expect(
          responder.registeredMethodBindings.keys,
          contains('${contract.serviceName}.recovered'),
        );
        await responder.close();
      }
    });

    test('a half-registered contract does not serve requests', () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      responder.registerServiceContract(_ServiceAWithDottedMethod());
      try {
        responder.registerServiceContract(_CollidesOnItsSecondMethod());
      } on RpcStatusException {
        // expected
      }
      responder.start();
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      await expectLater(
        caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'a.b',
          methodName: 'ok',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
        ),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.unimplemented,
          ),
        ),
        reason:
            'a method from a contract whose registration FAILED answered '
            'requests',
      );
    });
  });

  group('GUARD: registration still works, and still refuses what it must', () {
    test('a clean contract registers and serves', () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Fine('Svc'))
        ..start();
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      expect(responder.registeredMethodBindings.keys, ['Svc.recovered']);
      final r = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'recovered',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(r.value, 'answered');
    });

    test('a duplicate service is still refused', () async {
      // The commit-at-the-end form must not turn a genuine duplicate into a
      // silent overwrite.
      final (_, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(responder.close);
      responder.registerServiceContract(_Fine('Svc'));

      expect(
        () => responder.registerServiceContract(_Fine('Svc')),
        throwsA(isA<RpcStatusException>()),
      );
      expect(responder.registeredContracts.keys, ['Svc']);
    });

    test('a duplicate method key across services is still refused', () async {
      final (_, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(responder.close);
      responder.registerServiceContract(_ServiceAWithDottedMethod());

      expect(
        () => responder.registerServiceContract(_CollidesOnItsSecondMethod()),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.message,
            'message',
            contains('a.b.c'),
          ),
        ),
        reason: 'deferring the commit must not defer the CHECK',
      );
    });
  });
}
