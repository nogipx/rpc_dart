// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcCallScope', () {
    test('starts open, isClosed is false', () {
      final scope = RpcCallScope();
      expect(scope.isClosed, isFalse);
    });

    test('close() sets isClosed to true', () async {
      final scope = RpcCallScope();
      await scope.close();
      expect(scope.isClosed, isTrue);
    });

    test('done completes when scope closes', () async {
      final scope = RpcCallScope();
      var done = false;
      unawaited(scope.done.then((_) => done = true));

      await scope.close();
      await Future.delayed(Duration.zero);

      expect(done, isTrue);
    });

    test('double close is safe', () async {
      final scope = RpcCallScope();
      await scope.close();
      await scope.close(); // should not throw
      expect(scope.isClosed, isTrue);
    });

    group('onDispose', () {
      test('runs callbacks on close', () async {
        final scope = RpcCallScope();
        var called = false;
        scope.onDispose(() => called = true);

        await scope.close();
        expect(called, isTrue);
      });

      test('runs callbacks in reverse (LIFO) order', () async {
        final scope = RpcCallScope();
        final order = <int>[];

        scope.onDispose(() => order.add(1));
        scope.onDispose(() => order.add(2));
        scope.onDispose(() => order.add(3));

        await scope.close();
        expect(order, [3, 2, 1]);
      });

      test('callback registered after close runs immediately', () async {
        final scope = RpcCallScope();
        await scope.close();

        var called = false;
        scope.onDispose(() => called = true);
        await Future.delayed(Duration.zero);

        expect(called, isTrue);
      });

      test('errors in disposers do not prevent others from running', () async {
        final scope = RpcCallScope();
        final order = <int>[];

        scope.onDispose(() => order.add(1));
        scope.onDispose(() => throw Exception('boom'));
        scope.onDispose(() => order.add(3));

        await scope.close();
        expect(order, [3, 1]); // 3 first (reverse), then 1; error skipped
      });
    });

    group('track', () {
      test('mirrors source stream', () async {
        final scope = RpcCallScope();
        final source = StreamController<int>();

        final tracked = scope.track(source.stream);
        final results = <int>[];
        final sub = tracked.listen(results.add);

        source.add(1);
        source.add(2);
        await Future.delayed(Duration.zero);

        expect(results, [1, 2]);

        await sub.cancel();
        await source.close();
        await scope.close();
      });

      test('auto-cancels on scope close', () async {
        final scope = RpcCallScope();
        final source = StreamController<int>();

        final tracked = scope.track(source.stream);
        final results = <int>[];
        tracked.listen(results.add);

        source.add(1);
        await Future.delayed(Duration.zero);

        await scope.close();

        source.add(2); // should not reach listener
        await Future.delayed(Duration.zero);

        expect(results, [1]);
        await source.close();
      });

      test('returns done stream if scope already closed', () async {
        final scope = RpcCallScope();
        await scope.close();

        // track() on a closed scope returns a stream that completes
        // immediately with no events.
        final tracked = scope.track(Stream.fromIterable([1, 2, 3]));
        final results = await tracked.toList();
        expect(results, isEmpty);
      });
    });

    group('listen', () {
      test('auto-cancels subscription on scope close', () async {
        final scope = RpcCallScope();
        final source = StreamController<int>();

        final results = <int>[];
        scope.listen<int>(source.stream, results.add);

        source.add(1);
        await Future.delayed(Duration.zero);
        expect(results, [1]);

        await scope.close();

        source.add(2);
        await Future.delayed(Duration.zero);
        expect(results, [1]); // no 2

        await source.close();
      });

      test('returns usable subscription', () async {
        final scope = RpcCallScope();
        final source = StreamController<int>();

        final results = <int>[];
        final sub = scope.listen<int>(source.stream, results.add);

        source.add(1);
        await Future.delayed(Duration.zero);
        expect(results, [1]);

        // Manual cancel before scope close.
        await sub.cancel();

        source.add(2);
        await Future.delayed(Duration.zero);
        expect(results, [1]);

        await source.close();
        await scope.close();
      });
    });

    group('deadline', () {
      test('auto-closes scope when deadline expires', () async {
        final context = RpcContext.withTimeout(Duration(milliseconds: 50));
        final scope = RpcCallScope(context: context);

        expect(scope.isClosed, isFalse);
        expect(scope.remaining, isNotNull);

        await Future.delayed(Duration(milliseconds: 100));
        expect(scope.isClosed, isTrue);
      });

      test('runs disposers when deadline expires', () async {
        final context = RpcContext.withTimeout(Duration(milliseconds: 50));
        final scope = RpcCallScope(context: context);

        var cleaned = false;
        scope.onDispose(() => cleaned = true);

        await Future.delayed(Duration(milliseconds: 100));
        expect(cleaned, isTrue);
      });

      test('already expired deadline closes immediately', () async {
        final context = RpcContext.withDeadline(
          DateTime.now().subtract(Duration(seconds: 1)),
        );
        final scope = RpcCallScope(context: context);

        await Future.delayed(Duration.zero);
        expect(scope.isClosed, isTrue);
      });
    });

    group('cancellation', () {
      test('auto-closes scope when token is cancelled', () async {
        final token = RpcCancellationToken();
        final context = RpcContext.withCancellation(token);
        final scope = RpcCallScope(context: context);

        expect(scope.isClosed, isFalse);

        token.cancel('test');
        await Future.delayed(Duration.zero);

        expect(scope.isClosed, isTrue);
      });

      test('runs disposers on cancellation', () async {
        final token = RpcCancellationToken();
        final context = RpcContext.withCancellation(token);
        final scope = RpcCallScope(context: context);

        var cleaned = false;
        scope.onDispose(() => cleaned = true);

        token.cancel('test');
        await Future.delayed(Duration.zero);

        expect(cleaned, isTrue);
      });

      test('already cancelled token closes immediately', () async {
        final token = RpcCancellationToken.cancelled('pre-cancelled');
        final context = RpcContext.withCancellation(token);
        final scope = RpcCallScope(context: context);

        await Future.delayed(Duration.zero);
        expect(scope.isClosed, isTrue);
      });
    });

    group('remaining', () {
      test('returns null without context', () {
        final scope = RpcCallScope();
        expect(scope.remaining, isNull);
      });

      test('returns null without deadline', () {
        final scope = RpcCallScope(context: RpcContext.empty());
        expect(scope.remaining, isNull);
      });

      test('returns positive duration before deadline', () {
        final context = RpcContext.withTimeout(Duration(seconds: 10));
        final scope = RpcCallScope(context: context);

        final rem = scope.remaining;
        expect(rem, isNotNull);
        expect(rem!.inSeconds, greaterThan(0));

        scope.close();
      });
    });

    group('dx helpers', () {
      test('use registers a disposer and returns the resource', () async {
        final scope = RpcCallScope(context: RpcContext.empty());
        final disposed = <String>[];

        final resource = scope.use('conn', (c) => disposed.add(c));
        expect(resource, 'conn');
        expect(disposed, isEmpty);

        await scope.close();
        expect(disposed, ['conn']);
      });

      test('requireCallScope returns the scope when present', () {
        final scope = RpcCallScope(context: RpcContext.empty());
        final ctx = RpcContext.empty().withValue(RpcCallScope, scope);
        expect(ctx.requireCallScope(), same(scope));
      });

      test('requireCallScope throws when no scope is present', () {
        expect(RpcContext.empty().requireCallScope, throwsStateError);
      });
    });

    group('integration with endpoint', () {
      test(
        'scope is exposed to the handler and disposed after the call',
        () async {
          final (clientTransport, serverTransport) =
              RpcChannelTransport.memoryPair();

          final caller = RpcCallerEndpoint(transport: clientTransport);
          final responder = RpcResponderEndpoint(transport: serverTransport);

          RpcCallScope? captured;
          var disposed = false;
          responder.registerServiceContract(
            _ScopeTestContract(
              onScope: (scope) {
                captured = scope;
                scope?.onDispose(() => disposed = true);
              },
            ),
          );
          responder.start();

          final response = await caller
              .unaryRequest<_TestRequest, _TestResponse>(
                serviceName: 'TestService',
                methodName: 'Echo',
                requestCodec: _TestRequest.codec,
                responseCodec: _TestResponse.codec,
                request: _TestRequest('hello'),
              );

          expect(response.value, 'hello');
          // The handler now receives a real per-call scope (was null before).
          expect(captured, isNotNull);

          // When the server finishes the call it cleans up the stream and closes
          // the scope, running the handler-registered disposer.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(disposed, isTrue);

          await caller.close();
          await responder.close();
        },
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

final class _TestRequest implements IRpcSerializable {
  final String value;
  const _TestRequest(this.value);

  factory _TestRequest.fromJson(Map<String, dynamic> json) =>
      _TestRequest(json['value'] as String);

  @override
  Map<String, dynamic> toJson() => {'value': value};

  static RpcCodec<_TestRequest> get codec => RpcCodec(_TestRequest.fromJson);
}

final class _TestResponse implements IRpcSerializable {
  final String value;
  const _TestResponse(this.value);

  factory _TestResponse.fromJson(Map<String, dynamic> json) =>
      _TestResponse(json['value'] as String);

  @override
  Map<String, dynamic> toJson() => {'value': value};

  static RpcCodec<_TestResponse> get codec => RpcCodec(_TestResponse.fromJson);
}

final class _ScopeTestContract extends RpcResponderContract {
  final void Function(RpcCallScope? scope) onScope;

  _ScopeTestContract({required this.onScope}) : super('TestService');

  @override
  void setup() {
    addUnaryMethod<_TestRequest, _TestResponse>(
      methodName: 'Echo',
      handler: _echo,
      requestCodec: _TestRequest.codec,
      responseCodec: _TestResponse.codec,
    );
  }

  Future<_TestResponse> _echo(
    _TestRequest request, {
    RpcContext? context,
  }) async {
    onScope(context?.callScope);
    return _TestResponse(request.value);
  }
}
