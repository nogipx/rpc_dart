// Audit finding 9: restart after a failed start threw LateInitializationError.
// Source: lib/src/rpc_app.dart — `_modules`, `_container`, `_env`,
// `_autoInterceptors` are `late final`, assigned inside start(). On a failed
// start, `_started` is reset to false but those late final fields stay
// initialized; a second start() re-entered and reassigned them, throwing
// LateInitializationError and masking the real failure.
//
// Fix (single-shot start): a second start() after any prior attempt throws a
// clear StateError. A failed start must surface the ORIGINAL exception; a later
// start() must not throw LateInitializationError.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class FailingModule extends RpcModule {
  @override
  String get name => 'FailingModule';
  @override
  Future<void> onStart(RpcContainer container) async {
    throw StateError('boom in onStart');
  }
}

class _FakeServer implements IRpcServer {
  bool _running = false;
  @override
  bool get isRunning => _running;
  @override
  List<RpcResponderEndpoint> get endpoints => const [];
  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}

void main() {
  test('start() after a failed start throws a clear StateError, '
      'never LateInitializationError', () async {
    final app = RpcApp.server(
      modules: [FailingModule()],
      server: (_) => _FakeServer(),
    );

    // First start fails with the ORIGINAL error.
    await expectLater(app.start(), throwsA(isA<StateError>()));

    // Second start must NOT throw LateInitializationError. It throws a clear
    // single-shot StateError instead.
    Object? thrown;
    try {
      await app.start();
    } catch (e) {
      thrown = e;
    }

    expect(thrown, isNotNull, reason: 'second start() must throw');
    expect(thrown.runtimeType.toString(), isNot('LateInitializationError'),
        reason: 'restart must not surface LateInitializationError');
    expect(thrown, isA<StateError>());
    expect(thrown.toString(), contains('can only be called once'));
  });
}
