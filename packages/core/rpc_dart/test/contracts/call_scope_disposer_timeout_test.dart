// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallScope.close() awaited every disposer without a bound, and it sits on
// the shutdown path: _cleanupStream -> callScope.close(), and
// closeResponderResources runs that for every open stream. So one handler
// registering a disposer that never completes -- a flush to a dead socket, a
// lock nobody releases -- stopped the whole endpoint from shutting down.
//
// Measured with a single such handler: responder.close() was still unfinished
// after 4s and stayed that way. With the bound it returns in ~509ms against a
// 500ms timeout.
//
// The disposer is abandoned, not cancelled -- an arbitrary Future cannot be
// cancelled -- so it may still be running afterwards. That is strictly better
// than never shutting down, and it is logged rather than hidden.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Completer<void> _started = Completer<void>();
List<String> _ran = [];

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'stuck',
      handler: (r, {RpcContext? context}) async* {
        context?.getValue<RpcCallScope>(RpcCallScope)?.onDispose(() async {
          _ran.add('stuck-start');
          await Completer<void>().future; // never completes
        });
        if (!_started.isCompleted) _started.complete();
        yield 'a'.rpc;
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ordered',
      handler: (r, {RpcContext? context}) async* {
        final scope = context?.getValue<RpcCallScope>(RpcCallScope);
        // LIFO: 'second' must run before 'first'. The middle one hangs, and
        // must not strand the one registered before it.
        scope?.onDispose(() => _ran.add('first'));
        scope?.onDispose(() async {
          _ran.add('hang-start');
          await Completer<void>().future;
        });
        scope?.onDispose(() => _ran.add('third'));
        if (!_started.isCompleted) _started.complete();
        yield 'a'.rpc;
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'clean',
      handler: (r, {RpcContext? context}) async* {
        context?.getValue<RpcCallScope>(RpcCallScope)?.onDispose(() {
          _ran.add('clean');
        });
        if (!_started.isCompleted) _started.complete();
        yield 'a'.rpc;
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

/// Starts [method] and waits until its handler has registered its disposers.
Future<StreamSubscription<RpcString>> _start(_Rig rig, String method) async {
  final sub = rig.caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: method,
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen((_) {}, onError: (Object _) {});
  await _started.future.timeout(const Duration(seconds: 5));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return sub;
}

void main() {
  late Duration original;

  setUp(() {
    _started = Completer<void>();
    _ran = [];
    original = RpcCallScope.disposerTimeout;
    RpcCallScope.disposerTimeout = const Duration(milliseconds: 400);
  });
  tearDown(() => RpcCallScope.disposerTimeout = original);

  group('a stuck disposer cannot block shutdown', () {
    test('the endpoint still closes', () async {
      final rig = _connect();
      final sub = await _start(rig, 'stuck');

      final sw = Stopwatch()..start();
      await rig.responder.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('responder.close() hung on a disposer that never completes'),
      );
      sw.stop();

      expect(
        _ran,
        contains('stuck-start'),
        reason: 'it should have been tried',
      );
      expect(
        sw.elapsedMilliseconds,
        lessThan(3000),
        reason: 'close took ${sw.elapsedMilliseconds}ms',
      );

      await sub.cancel();
      await rig.caller.close();
      await rig.client.close();
      await rig.server.close();
    });

    test('the disposers around it still run', () async {
      // LIFO order, with the hanging one in the middle: the one registered
      // before it must not be stranded.
      final rig = _connect();
      final sub = await _start(rig, 'ordered');

      await rig.responder.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('responder.close() hung'),
      );

      expect(_ran, ['third', 'hang-start', 'first']);

      await sub.cancel();
      await rig.caller.close();
      await rig.client.close();
      await rig.server.close();
    });
  });

  group('ordinary cleanup is unaffected', () {
    test(
      'a disposer that completes runs and does not wait out the bound',
      () async {
        final rig = _connect();
        final sub = await _start(rig, 'clean');

        final sw = Stopwatch()..start();
        await rig.responder.close().timeout(const Duration(seconds: 5));
        sw.stop();

        expect(_ran, ['clean']);
        expect(
          sw.elapsedMilliseconds,
          lessThan(300),
          reason: 'a prompt disposer must not pay the timeout',
        );

        await sub.cancel();
        await rig.caller.close();
        await rig.client.close();
        await rig.server.close();
      },
    );

    test('a normal call closes cleanly with no disposer drama', () async {
      final rig = _connect();
      expect(
        await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'clean',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList()
            .timeout(const Duration(seconds: 5)),
        hasLength(1),
      );
      await rig.caller.close();
      await rig.responder.close();
      await rig.client.close();
      await rig.server.close();
    });

    test('the default bound is generous enough for real cleanup', () {
      expect(original, greaterThanOrEqualTo(const Duration(seconds: 1)));
    });
  });
}
