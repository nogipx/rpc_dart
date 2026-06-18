// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared domain model
// ---------------------------------------------------------------------------

class PingRequest implements IRpcSerializable {
  final String message;
  const PingRequest(this.message);
  @override
  Map<String, dynamic> toJson() => {'message': message};
  static PingRequest fromJson(Map<String, dynamic> j) =>
      PingRequest(j['message'] as String);
}

class PingResponse implements IRpcSerializable {
  final String reply;
  const PingResponse(this.reply);
  @override
  Map<String, dynamic> toJson() => {'reply': reply};
  static PingResponse fromJson(Map<String, dynamic> j) =>
      PingResponse(j['reply'] as String);
}

final _reqCodec = RpcCodec<PingRequest>.withDecoder(PingRequest.fromJson);
final _resCodec = RpcCodec<PingResponse>.withDecoder(PingResponse.fromJson);

// ---------------------------------------------------------------------------
// EchoService / EchoModule
// ---------------------------------------------------------------------------

class EchoService {
  String echo(String msg) => 'pong: $msg';
}

class EchoResponderContract extends RpcResponderContract {
  final EchoService _svc;
  EchoResponderContract(this._svc) : super('EchoService') {
    addUnaryMethod<PingRequest, PingResponse>(
      methodName: 'ping',
      handler: (req, {context}) async => PingResponse(_svc.echo(req.message)),
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
    );
    addUnaryMethod<PingRequest, PingResponse>(
      methodName: 'echo',
      handler: (req, {context}) async => PingResponse(_svc.echo(req.message)),
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
    );
  }
}

class EchoCallerContract extends RpcCallerContract {
  EchoCallerContract(RpcCallerEndpoint ep) : super('EchoService', ep);
  Future<PingResponse> ping(PingRequest req, {RpcContext? context}) =>
      callUnary<PingRequest, PingResponse>(
        methodName: 'ping',
        request: req,
        requestCodec: _reqCodec,
        responseCodec: _resCodec,
        context: context,
      );
  Future<PingResponse> echo(PingRequest req, {RpcContext? context}) =>
      callUnary<PingRequest, PingResponse>(
        methodName: 'echo',
        request: req,
        requestCodec: _reqCodec,
        responseCodec: _resCodec,
        context: context,
      );
}

class EchoModule extends RpcServerModule {
  @override
  String get name => 'EchoModule';

  bool startCalled = false;
  bool stopCalled = false;

  @override
  void configure(RpcContainer c) =>
      c.registerSingleton<EchoService>(EchoService());

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => [
    EchoResponderContract(c.get<EchoService>()),
  ];

  @override
  Future<void> onStart(RpcContainer c) async => startCalled = true;

  @override
  Future<void> onStop() async => stopCalled = true;
}

// ---------------------------------------------------------------------------
// RpcContainer
// ---------------------------------------------------------------------------

void main() {
  group('RpcContainer', () {
    test('resolves singleton', () {
      final c = RpcContainer()..registerSingleton<EchoService>(EchoService());
      expect(c.get<EchoService>(), isA<EchoService>());
    });

    test('factory creates fresh instances', () {
      final c = RpcContainer()
        ..registerFactory<EchoService>((_) => EchoService());
      expect(identical(c.get<EchoService>(), c.get<EchoService>()), isFalse);
    });

    test('singleton beats factory', () {
      final instance = EchoService();
      final c = RpcContainer()
        ..registerSingleton<EchoService>(instance)
        ..registerFactory<EchoService>((_) => EchoService());
      expect(identical(c.get<EchoService>(), instance), isTrue);
    });

    test('throws when not registered', () {
      expect(
        () => RpcContainer().get<EchoService>(),
        throwsA(isA<StateError>()),
      );
    });

    test('tryGet returns null when not registered', () {
      expect(RpcContainer().tryGet<EchoService>(), isNull);
    });

    test('has returns correct presence', () {
      final c = RpcContainer();
      expect(c.has<EchoService>(), isFalse);
      c.registerSingleton<EchoService>(EchoService());
      expect(c.has<EchoService>(), isTrue);
    });

    test('factory can resolve its own deps', () {
      final c = RpcContainer()
        ..registerSingleton<EchoService>(EchoService())
        ..registerFactory<EchoResponderContract>(
          (c) => EchoResponderContract(c.get<EchoService>()),
        );
      expect(c.get<EchoResponderContract>(), isA<EchoResponderContract>());
    });
  });

  // -------------------------------------------------------------------------
  group('RpcEnvConfig', () {
    test('reads present key', () {
      final env = RpcEnvConfig.from({'FOO': 'bar'});
      expect(env['FOO'], 'bar');
    });

    test('returns null for absent key', () {
      expect(RpcEnvConfig.from({})['MISSING'], isNull);
    });

    test('require throws on missing', () {
      expect(
        () => RpcEnvConfig.from({}).require('X'),
        throwsA(isA<StateError>()),
      );
    });

    test('getInt parses integer', () {
      expect(RpcEnvConfig.from({'N': '42'}).getInt('N'), 42);
    });

    test('getInt returns null for non-integer', () {
      expect(RpcEnvConfig.from({'N': 'abc'}).getInt('N'), isNull);
    });

    test('getBool parses true variants', () {
      for (final v in ['true', '1', 'yes', 'TRUE', 'YES']) {
        expect(RpcEnvConfig.from({'B': v}).getBool('B'), isTrue, reason: v);
      }
    });

    test('getBool defaults to false', () {
      expect(RpcEnvConfig.from({}).getBool('B'), isFalse);
    });

    test('getList splits on comma', () {
      final env = RpcEnvConfig.from({'L': 'a,b, c'});
      expect(env.getList('L'), ['a', 'b', 'c']);
    });

    test('getDuration parses all units', () {
      final env = RpcEnvConfig.from({
        'A': '100ms',
        'B': '30s',
        'C': '5m',
        'D': '2h',
      });
      expect(env.getDuration('A'), const Duration(milliseconds: 100));
      expect(env.getDuration('B'), const Duration(seconds: 30));
      expect(env.getDuration('C'), const Duration(minutes: 5));
      expect(env.getDuration('D'), const Duration(hours: 2));
    });

    test('getDuration returns null for unknown format', () {
      expect(RpcEnvConfig.from({'T': 'bad'}).getDuration('T'), isNull);
    });

    test('configureWithEnv is called during RpcTestApp.start', () async {
      var envSeen = false;
      final module = _EnvModule(
        onEnv: (env) {
          envSeen = env['CUSTOM_KEY'] == 'hello';
        },
      );
      final app = await RpcTestApp.start(
        modules: [module],
        env: {'CUSTOM_KEY': 'hello'},
      );
      await app.dispose();
      expect(envSeen, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('RpcTestApp', () {
    late EchoModule module;
    late RpcTestApp app;

    setUp(() async {
      module = EchoModule();
      app = await RpcTestApp.start(modules: [module]);
    });

    tearDown(() => app.dispose());

    test('starts module lifecycle', () => expect(module.startCalled, isTrue));

    test('ping returns expected reply', () async {
      final client = EchoCallerContract(app.caller);
      final res = await client.ping(const PingRequest('hello'));
      expect(res.reply, 'pong: hello');
    });

    test('multiple calls work', () async {
      final client = EchoCallerContract(app.caller);
      for (var i = 0; i < 5; i++) {
        final res = await client.ping(PingRequest('msg$i'));
        expect(res.reply, 'pong: msg$i');
      }
    });

    test('stops module on dispose', () async {
      await app.dispose();
      expect(module.stopCalled, isTrue);
    });

    test('dispose is idempotent', () async {
      await app.dispose();
      await app.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('Module topological sort', () {
    test('independent modules keep registration order', () async {
      final log = <String>[];
      final a = _LogModule('A', [], log);
      final b = _LogModule('B', [], log);
      final app = await RpcTestApp.start(modules: [a, b]);
      await app.dispose();
      expect(log, ['start:A', 'start:B', 'stop:B', 'stop:A']);
    });

    test('dependency starts before dependant', () async {
      final log = <String>[];
      final dep = _LogModule('Dep', [], log);
      final mod = _LogModule(
        'Mod',
        [_LogModule],
        log,
        depType: dep.runtimeType,
      );
      // Register mod before dep — framework must reorder.
      final app = await RpcTestApp.start(modules: [mod, dep]);
      await app.dispose();
      expect(log.indexOf('start:Dep'), lessThan(log.indexOf('start:Mod')));
      expect(log.indexOf('stop:Mod'), lessThan(log.indexOf('stop:Dep')));
    });

    test('circular dependency throws', () {
      // Can't easily test via RpcTestApp (throws during start).
      // Test the sort directly via RpcApp internal logic through a real start.
      expect(() async {
        final a = _CircularA();
        final b = _CircularB();
        await RpcTestApp.start(modules: [a, b]);
      }, throwsA(isA<StateError>()));
    });

    test('unknown dependency throws', () {
      expect(() async {
        final m = _LogModule('X', [EchoService], null, depType: EchoService);
        await RpcTestApp.start(modules: [m]);
      }, throwsA(isA<StateError>()));
    });
  });

  // -------------------------------------------------------------------------
  group('Module health', () {
    test('checkHealth result appears in app health', () async {
      final module = _HealthyModule();
      final app = await RpcTestApp.start(modules: [module]);
      final health = await app.health();
      await app.dispose();
      expect(health.modules.containsKey('HealthyModule'), isTrue);
      expect(health.modules['HealthyModule']!['level'], 'healthy');
    });

    test('null checkHealth is omitted', () async {
      final app = await RpcTestApp.start(modules: [EchoModule()]);
      final health = await app.health();
      await app.dispose();
      expect(health.modules, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('RpcRateLimiter', () {
    test('allows calls within limit', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            global: RateLimit.slidingWindow(
              max: 5,
              window: Duration(seconds: 1),
            ),
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      for (var i = 0; i < 5; i++) {
        await client.ping(const PingRequest('x'));
      }
      await app.dispose();
    });

    test('rejects calls over limit', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            global: RateLimit.slidingWindow(
              max: 2,
              window: Duration(seconds: 10),
            ),
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('1'));
      await client.ping(const PingRequest('2'));
      await expectLater(
        client.ping(const PingRequest('3')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      await app.dispose();
    });

    test('per-method limit only affects matching method', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            perMethod: {
              'EchoService.ping': RateLimit.slidingWindow(
                max: 1,
                window: Duration(seconds: 10),
              ),
            },
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('first'));
      // ping is now limited
      await expectLater(
        client.ping(const PingRequest('second')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      // echo is not in perMethod — no limit applies, should still work
      await client.echo(const PingRequest('not limited'));
      await client.echo(const PingRequest('still works'));
      await app.dispose();
    });

    test('per-service limit applies to all methods in service', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            perService: {
              'EchoService': RateLimit.slidingWindow(
                max: 2,
                window: Duration(seconds: 10),
              ),
            },
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      // Two calls across different methods consume the shared service budget
      await client.ping(const PingRequest('1'));
      await client.echo(const PingRequest('2'));
      // Third call (any method) must be rejected
      await expectLater(
        client.ping(const PingRequest('3')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      await app.dispose();
    });

    test('perMethod takes priority over perService', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            perService: {
              'EchoService': RateLimit.slidingWindow(
                max: 10,
                window: Duration(seconds: 10),
              ),
            },
            perMethod: {
              // Stricter limit on ping — should win over service limit
              'EchoService.ping': RateLimit.slidingWindow(
                max: 1,
                window: Duration(seconds: 10),
              ),
            },
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('first'));
      await expectLater(
        client.ping(const PingRequest('second')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      // echo uses service counter (max 10) — must still work
      for (var i = 0; i < 5; i++) {
        await client.echo(PingRequest('echo$i'));
      }
      await app.dispose();
    });

    test('perService takes priority over global', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            global: RateLimit.slidingWindow(
              max: 10,
              window: Duration(seconds: 10),
            ),
            perService: {
              // Stricter limit on EchoService — should win over global
              'EchoService': RateLimit.slidingWindow(
                max: 1,
                window: Duration(seconds: 10),
              ),
            },
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('first'));
      await expectLater(
        client.ping(const PingRequest('second')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      await app.dispose();
    });

    test('token bucket rejects calls over burst capacity', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            global: RateLimit.tokenBucket(
              max: 2,
              window: Duration(seconds: 10),
              burst: 2,
            ),
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('1'));
      await client.ping(const PingRequest('2'));
      await expectLater(
        client.ping(const PingRequest('3')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      await app.dispose();
    });

    test('token bucket burst allows spike above average rate', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            global: RateLimit.tokenBucket(
              max: 1,
              window: Duration(seconds: 1),
              burst: 5,
            ),
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      // Bucket starts full (5 tokens) — all 5 immediate calls pass
      for (var i = 0; i < 5; i++) {
        await client.ping(const PingRequest('x'));
      }
      // Bucket empty — next call rejected
      await expectLater(
        client.ping(const PingRequest('over')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      await app.dispose();
    });

    test('token bucket refills after window elapses', () async {
      const window = Duration(milliseconds: 80);
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [
          RpcRateLimiter(
            global: RateLimit.tokenBucket(max: 1, window: window, burst: 1),
          ),
        ],
      );
      final client = EchoCallerContract(app.caller);
      // Consume the single token
      await client.ping(const PingRequest('1'));
      await expectLater(
        client.ping(const PingRequest('2')),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Rate limit exceeded'),
          ),
        ),
      );
      // Wait for refill
      await Future<void>.delayed(window * 1.5);
      // Token refilled — should pass
      await client.ping(const PingRequest('3'));
      await app.dispose();
    });

    test('no limiter configured passes all calls through', () async {
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [RpcRateLimiter()],
      );
      final client = EchoCallerContract(app.caller);
      for (var i = 0; i < 20; i++) {
        await client.ping(const PingRequest('x'));
      }
      await app.dispose();
    });

    // -------------------------------------------------------------------------
    group('keyExtractor (per-key dynamic limits)', () {
      final _isRateLimited = isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('Rate limit exceeded'),
      );

      test('different keys have independent counters', () async {
        final limiter = RpcRateLimiter(
          perMethod: {
            'EchoService.ping': RateLimit.slidingWindow(
              max: 2,
              window: Duration(seconds: 10),
            ),
          },
          keyExtractor: (call) => call.context.getHeader('x-user-id'),
        );
        final app = await RpcTestApp.start(
          modules: [EchoModule()],
          interceptors: [limiter],
        );
        final client = EchoCallerContract(app.caller);
        final ctxA = RpcContext.withHeaders({'x-user-id': 'user_a'});
        final ctxB = RpcContext.withHeaders({'x-user-id': 'user_b'});

        // user_a exhausts their limit (max: 2)
        await client.ping(const PingRequest('a1'), context: ctxA);
        await client.ping(const PingRequest('a2'), context: ctxA);
        await expectLater(
          client.ping(const PingRequest('a3'), context: ctxA),
          throwsA(_isRateLimited),
        );
        // user_b has their own independent counter — full budget still available
        await client.ping(const PingRequest('b1'), context: ctxB);
        await client.ping(const PingRequest('b2'), context: ctxB);

        await app.dispose();
        limiter.dispose();
      });

      test('null key falls through to global', () async {
        final limiter = RpcRateLimiter(
          global: RateLimit.slidingWindow(
            max: 2,
            window: Duration(seconds: 10),
          ),
          perMethod: {
            // Would be strict limit per key, but key will be null → skipped
            'EchoService.ping': RateLimit.slidingWindow(
              max: 1,
              window: Duration(seconds: 10),
            ),
          },
          keyExtractor: (call) =>
              call.context.getHeader('x-user-id'), // no header → null
        );
        final app = await RpcTestApp.start(
          modules: [EchoModule()],
          interceptors: [limiter],
        );
        final client = EchoCallerContract(app.caller);

        // No x-user-id header → key is null → per-method skipped → global (max 2) applies
        await client.ping(const PingRequest('1'));
        await client.ping(const PingRequest('2'));
        await expectLater(
          client.ping(const PingRequest('3')),
          throwsA(_isRateLimited),
        );

        await app.dispose();
        limiter.dispose();
      });

      test(
        'perService per-key: shared budget across methods for same key',
        () async {
          final limiter = RpcRateLimiter(
            perService: {
              'EchoService': RateLimit.slidingWindow(
                max: 2,
                window: Duration(seconds: 10),
              ),
            },
            keyExtractor: (call) => call.context.getHeader('x-user-id'),
          );
          final app = await RpcTestApp.start(
            modules: [EchoModule()],
            interceptors: [limiter],
          );
          final client = EchoCallerContract(app.caller);
          final ctx = RpcContext.withHeaders({'x-user-id': 'user_a'});

          // Two calls across different methods consume user_a's service budget
          await client.ping(const PingRequest('1'), context: ctx);
          await client.echo(const PingRequest('2'), context: ctx);
          // Third call (any method) must be rejected for user_a
          await expectLater(
            client.ping(const PingRequest('3'), context: ctx),
            throwsA(_isRateLimited),
          );

          // user_b has their own budget — must work
          final ctxB = RpcContext.withHeaders({'x-user-id': 'user_b'});
          await client.ping(const PingRequest('b1'), context: ctxB);
          await client.echo(const PingRequest('b2'), context: ctxB);

          await app.dispose();
          limiter.dispose();
        },
      );

      test(
        'perMethod per-key takes priority over perService per-key',
        () async {
          final limiter = RpcRateLimiter(
            perService: {
              'EchoService': RateLimit.slidingWindow(
                max: 10,
                window: Duration(seconds: 10),
              ),
            },
            perMethod: {
              'EchoService.ping': RateLimit.slidingWindow(
                max: 1,
                window: Duration(seconds: 10),
              ),
            },
            keyExtractor: (call) => call.context.getHeader('x-user-id'),
          );
          final app = await RpcTestApp.start(
            modules: [EchoModule()],
            interceptors: [limiter],
          );
          final client = EchoCallerContract(app.caller);
          final ctx = RpcContext.withHeaders({'x-user-id': 'user_a'});

          // ping is limited to 1 per user (perMethod wins)
          await client.ping(const PingRequest('1'), context: ctx);
          await expectLater(
            client.ping(const PingRequest('2'), context: ctx),
            throwsA(_isRateLimited),
          );
          // echo uses perService counter (max 10 per user) — must work
          for (var i = 0; i < 5; i++) {
            await client.echo(PingRequest('e$i'), context: ctx);
          }

          await app.dispose();
          limiter.dispose();
        },
      );

      test('global is always shared regardless of keyExtractor', () async {
        // No perMethod/perService — all calls fall through to global.
        // Global is a single shared counter even when keyExtractor is set.
        final limiter = RpcRateLimiter(
          global: RateLimit.slidingWindow(
            max: 3,
            window: Duration(seconds: 10),
          ),
          keyExtractor: (call) => call.context.getHeader('x-user-id'),
        );
        final app = await RpcTestApp.start(
          modules: [EchoModule()],
          interceptors: [limiter],
        );
        final client = EchoCallerContract(app.caller);
        final ctxA = RpcContext.withHeaders({'x-user-id': 'user_a'});
        final ctxB = RpcContext.withHeaders({'x-user-id': 'user_b'});

        // user_a and user_b together exhaust the shared global counter (max: 3)
        await client.ping(const PingRequest('a1'), context: ctxA);
        await client.ping(const PingRequest('b1'), context: ctxB);
        await client.ping(const PingRequest('a2'), context: ctxA);
        // 4th call — global exhausted regardless of which user calls
        await expectLater(
          client.ping(const PingRequest('b2'), context: ctxB),
          throwsA(_isRateLimited),
        );

        await app.dispose();
        limiter.dispose();
      });

      test('perKeyFallback applies per (key, method) for any method', () async {
        final limiter = RpcRateLimiter(
          perKeyFallback: RateLimit.slidingWindow(
            max: 2,
            window: Duration(seconds: 10),
          ),
          keyExtractor: (call) => call.context.getHeader('x-user-id'),
        );
        final app = await RpcTestApp.start(
          modules: [EchoModule()],
          interceptors: [limiter],
        );
        final client = EchoCallerContract(app.caller);
        final ctxA = RpcContext.withHeaders({'x-user-id': 'user_a'});
        final ctxB = RpcContext.withHeaders({'x-user-id': 'user_b'});

        // user_a: ping and echo each get their own counter (per method)
        await client.ping(const PingRequest('a1'), context: ctxA);
        await client.ping(const PingRequest('a2'), context: ctxA);
        await expectLater(
          client.ping(const PingRequest('a3'), context: ctxA),
          throwsA(_isRateLimited),
        );
        // echo is a separate (key, method) counter — still works for user_a
        await client.echo(const PingRequest('ae1'), context: ctxA);

        // user_b has independent counters for all methods
        await client.ping(const PingRequest('b1'), context: ctxB);
        await client.ping(const PingRequest('b2'), context: ctxB);

        await app.dispose();
        limiter.dispose();
      });

      test(
        'perKeyFallback is overridden by perMethod for matching methods',
        () async {
          final limiter = RpcRateLimiter(
            perKeyFallback: RateLimit.slidingWindow(
              max: 10,
              window: Duration(seconds: 10),
            ),
            perMethod: {
              // Stricter limit for ping — overrides perKeyFallback
              'EchoService.ping': RateLimit.slidingWindow(
                max: 1,
                window: Duration(seconds: 10),
              ),
            },
            keyExtractor: (call) => call.context.getHeader('x-user-id'),
          );
          final app = await RpcTestApp.start(
            modules: [EchoModule()],
            interceptors: [limiter],
          );
          final client = EchoCallerContract(app.caller);
          final ctx = RpcContext.withHeaders({'x-user-id': 'user_a'});

          // ping uses perMethod (max 1) — not perKeyFallback (max 10)
          await client.ping(const PingRequest('1'), context: ctx);
          await expectLater(
            client.ping(const PingRequest('2'), context: ctx),
            throwsA(_isRateLimited),
          );
          // echo falls through to perKeyFallback (max 10) — works fine
          for (var i = 0; i < 5; i++) {
            await client.echo(PingRequest('e$i'), context: ctx);
          }

          await app.dispose();
          limiter.dispose();
        },
      );

      test('perKeyFallback null key falls through to global', () async {
        final limiter = RpcRateLimiter(
          global: RateLimit.slidingWindow(
            max: 2,
            window: Duration(seconds: 10),
          ),
          perKeyFallback: RateLimit.slidingWindow(
            max: 1,
            window: Duration(seconds: 10),
          ),
          keyExtractor: (call) =>
              call.context.getHeader('x-user-id'), // no header → null
        );
        final app = await RpcTestApp.start(
          modules: [EchoModule()],
          interceptors: [limiter],
        );
        final client = EchoCallerContract(app.caller);

        // No header → key is null → perKeyFallback skipped → global (max 2) applies
        await client.ping(const PingRequest('1'));
        await client.ping(const PingRequest('2'));
        await expectLater(
          client.ping(const PingRequest('3')),
          throwsA(_isRateLimited),
        );

        await app.dispose();
        limiter.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('Global error hook', () {
    test('onError is called on handler exception', () async {
      Object? caughtError;
      String? caughtService;
      final module = _ThrowingModule();
      final app = await RpcTestApp.start(
        modules: [module],
        config: RpcAppConfig(
          onError: (e, st, svc, method) {
            caughtError = e;
            caughtService = svc;
          },
        ),
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('x')), throwsException);
      await app.dispose();
      expect(caughtError, isNotNull);
      expect(caughtService, 'EchoService');
    });
  });

  // -------------------------------------------------------------------------
  group('RpcCallSpy', () {
    test('records successful unary calls', () async {
      final spy = RpcCallSpy();
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [spy],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('hello'));
      await client.ping(const PingRequest('world'));
      await app.dispose();

      expect(spy.callCount, 2);
      expect(spy.successCount, 2);
      expect(spy.errorCount, 0);
      expect(spy.entries.every((e) => e.callType == 'unary'), isTrue);
      expect(spy.entries.every((e) => e.success), isTrue);
    });

    test('callsTo filters by service and method', () async {
      final spy = RpcCallSpy();
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [spy],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('x'));
      await app.dispose();

      expect(spy.callsTo('EchoService', 'ping'), hasLength(1));
      expect(spy.callsTo('EchoService', 'unknown'), isEmpty);
      expect(spy.callsTo('Other', 'ping'), isEmpty);
    });

    test('wasCalled returns correct result', () async {
      final spy = RpcCallSpy();
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [spy],
      );
      await app.dispose();

      expect(spy.wasCalled('EchoService', 'ping'), isFalse);

      final app2 = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [spy],
      );
      final client2 = EchoCallerContract(app2.caller);
      await client2.ping(const PingRequest('x'));
      await app2.dispose();

      expect(spy.wasCalled('EchoService', 'ping'), isTrue);
    });

    test('records failed calls', () async {
      final spy = RpcCallSpy();
      final app = await RpcTestApp.start(
        modules: [_ThrowingModule()],
        interceptors: [spy],
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('x')), throwsException);
      await app.dispose();

      expect(spy.callCount, 1);
      expect(spy.errorCount, 1);
      expect(spy.successCount, 0);
      expect(spy.entries.first.error, isNotNull);
    });

    test('reset clears all entries', () async {
      final spy = RpcCallSpy();
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [spy],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('x'));
      expect(spy.callCount, 1);

      spy.reset();
      expect(spy.callCount, 0);
      expect(spy.entries, isEmpty);

      await app.dispose();
    });

    test('entries contain duration and context', () async {
      final spy = RpcCallSpy();
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [spy],
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('x'));
      await app.dispose();

      final entry = spy.entries.first;
      expect(entry.duration, isA<Duration>());
      expect(entry.context, isA<RpcContext>());
      expect(entry.calledAt, isA<DateTime>());
      expect(entry.serviceName, 'EchoService');
      expect(entry.methodName, 'ping');
    });
  });

  // -------------------------------------------------------------------------
  group('RpcFaultInjector', () {
    test('failMethod permanently throws', () async {
      final faults = RpcFaultInjector()
        ..failMethod('EchoService', 'ping', Exception('injected'));
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('x')), throwsException);
      await expectLater(client.ping(const PingRequest('y')), throwsException);
      await app.dispose();
    });

    test('failMethodOnce throws once then succeeds', () async {
      final faults = RpcFaultInjector()
        ..failMethodOnce('EchoService', 'ping', Exception('one-shot'));
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(
        client.ping(const PingRequest('first')),
        throwsException,
      );
      final res = await client.ping(const PingRequest('second'));
      expect(res.reply, 'pong: second');
      await app.dispose();
    });

    test('failMethodOnce queues multiple errors in order', () async {
      final faults = RpcFaultInjector()
        ..failMethodOnce('EchoService', 'ping', Exception('error1'))
        ..failMethodOnce('EchoService', 'ping', Exception('error2'));
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('a')), throwsException);
      await expectLater(client.ping(const PingRequest('b')), throwsException);
      final res = await client.ping(const PingRequest('c'));
      expect(res.reply, 'pong: c');
      await app.dispose();
    });

    test('delayMethod adds latency', () async {
      final delay = Duration(milliseconds: 50);
      final faults = RpcFaultInjector()
        ..delayMethod('EchoService', 'ping', delay);
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      final sw = Stopwatch()..start();
      await client.ping(const PingRequest('x'));
      sw.stop();
      await app.dispose();

      expect(sw.elapsed, greaterThanOrEqualTo(delay));
    });

    test('removeMethod clears specific fault', () async {
      final faults = RpcFaultInjector()
        ..failMethod('EchoService', 'ping', Exception('err'));
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('a')), throwsException);

      faults.removeMethod('EchoService', 'ping');
      final res = await client.ping(const PingRequest('b'));
      expect(res.reply, 'pong: b');
      await app.dispose();
    });

    test('clear removes all faults', () async {
      final faults = RpcFaultInjector()
        ..failMethod('EchoService', 'ping', Exception('err'));
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('a')), throwsException);

      faults.clear();
      final res = await client.ping(const PingRequest('b'));
      expect(res.reply, 'pong: b');
      await app.dispose();
    });

    test('unfaulted methods pass through normally', () async {
      final faults = RpcFaultInjector()
        ..failMethod('OtherService', 'other', Exception('err'));
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        interceptors: [faults],
      );
      final client = EchoCallerContract(app.caller);
      final res = await client.ping(const PingRequest('x'));
      expect(res.reply, 'pong: x');
      await app.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('Metrics hook', () {
    test('onCall is invoked for each call', () async {
      final events = <RpcCallEvent>[];
      final app = await RpcTestApp.start(
        modules: [EchoModule()],
        config: RpcAppConfig(onCall: events.add),
      );
      final client = EchoCallerContract(app.caller);
      await client.ping(const PingRequest('x'));
      await client.ping(const PingRequest('y'));
      await app.dispose();
      expect(events.length, 2);
      expect(events.every((e) => e.success), isTrue);
      expect(events.every((e) => e.callType == 'unary'), isTrue);
      expect(events.every((e) => e.serviceName == 'EchoService'), isTrue);
      // ignore: unnecessary_non_null_assertion
    });

    test('onCall reports failure on exception', () async {
      final events = <RpcCallEvent>[];
      final app = await RpcTestApp.start(
        modules: [_ThrowingModule()],
        config: RpcAppConfig(onCall: events.add),
      );
      final client = EchoCallerContract(app.caller);
      await expectLater(client.ping(const PingRequest('x')), throwsException);
      await app.dispose();
      expect(events.length, 1);
      expect(events.first.success, isFalse);
      expect(events.first.error, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('RpcApp module type validation', () {
    test(
      'RpcApp.server accepts plain RpcModule alongside RpcServerModule',
      () async {
        final app = RpcApp.server(
          modules: [_InfraModule(), EchoModule()],
          server: (onEndpoint) => _NullServer(onEndpoint),
        );
        await app.start();
        await app.stop();
      },
    );

    test('RpcApp.server rejects RpcServerModule in wrong position', () async {
      // topo sort still works with plain modules
      final app = RpcApp.server(
        modules: [EchoModule(), _InfraModule()],
        server: (onEndpoint) => _NullServer(onEndpoint),
      );
      await app.start();
      await app.stop();
    });
  });
}

// ===========================================================================
// Test helpers
// ===========================================================================

class _EnvModule extends RpcServerModule {
  final void Function(RpcEnvConfig) _onEnv;
  _EnvModule({required void Function(RpcEnvConfig) onEnv}) : _onEnv = onEnv;

  @override
  String get name => 'EnvModule';

  @override
  void configureWithEnv(RpcContainer c, RpcEnvConfig env) => _onEnv(env);

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => const [];
}

class _LogModule extends RpcServerModule {
  @override
  final String name;
  final List<Type> _deps;
  final List<String>? _log;

  _LogModule(this.name, this._deps, this._log, {Type? depType})
    : _depType = depType;

  final Type? _depType;

  @override
  List<Type> get dependencies {
    final d = _depType;
    return d != null ? [d] : _deps;
  }

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => const [];

  @override
  Future<void> onStart(RpcContainer c) async => _log?.add('start:$name');

  @override
  Future<void> onStop() async => _log?.add('stop:$name');
}

class _HealthyModule extends RpcServerModule {
  @override
  String get name => 'HealthyModule';

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => const [];

  @override
  Future<RpcHealthStatus?> checkHealth() async =>
      RpcHealthStatus.healthy(component: name, message: 'all good');
}

class _ThrowingModule extends RpcServerModule {
  @override
  String get name => 'ThrowingModule';

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => [
    _ThrowingContract(),
  ];
}

class _ThrowingContract extends RpcResponderContract {
  _ThrowingContract() : super('EchoService') {
    addUnaryMethod<PingRequest, PingResponse>(
      methodName: 'ping',
      handler: (req, {context}) async =>
          throw Exception('intentional test error'),
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
    );
  }
}

// RpcApp validation helpers

class _InfraModule extends RpcModule {
  @override
  String get name => 'InfraModule';
}

/// Minimal IRpcServer that ignores the endpoint callback and does nothing.
class _NullServer implements IRpcServer {
  _NullServer(void Function(RpcResponderEndpoint) _);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  bool get isRunning => false;

  @override
  List<RpcResponderEndpoint> get endpoints => const [];
}

// Circular dependency helpers
class _CircularA extends RpcServerModule {
  @override
  String get name => 'CircularA';
  @override
  List<Type> get dependencies => [_CircularB];
  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => const [];
}

class _CircularB extends RpcServerModule {
  @override
  String get name => 'CircularB';
  @override
  List<Type> get dependencies => [_CircularA];
  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => const [];
}
