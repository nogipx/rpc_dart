// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The WEB half of the peer-death battery, which had never been run.
//
// The VM spawn() wires onError/onExit ports, fails spawn() when the isolate
// dies during startup, and closes the host channel when it dies afterwards.
// Its own comment states the purpose: a worker that crashes during startup
// must make spawn() throw "instead of returning a silently-dead transport".
//
// The web spawn() wired nothing equivalent -- no worker.onerror, no
// onmessageerror, no exit signal -- and took a `startupTimeout` parameter it
// never used: both waits were hard-coded `Duration(seconds: 5)` and BOTH
// swallowed the timeout with `onTimeout: () {}`. Measured in Chrome against a
// worker URI that 404s:
//
//   spawn() threw : NO -- returned a transport
//   spawn() took  : 10002ms          (the two swallowed 5s waits)
//   isClosed      : false
//   health        : healthy / Transport ready
//   a call on it  : HUNG, forever
//   startupTimeout: 1s requested, 10002ms taken, no throw
//
// A supervisor polling health() saw green for a worker that never existed, and
// every call hung with no error on either side. After: spawn() throws in ~4ms.
//
// Post-startup death is the same story: the worker kills itself with an
// uncaught async error (EchoService/Die), which in a dedicated Web Worker fires
// an `error` event on the parent's Worker object -- the ONLY death signal the
// web gives a host.
//
// Requires the compiled worker; see echo_worker_test.dart for the build step.
@TestOn('browser')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

void _unusedEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {}

Uri get _realWorker => Uri.base.resolve('echo_worker.dart.js');
Uri get _missingWorker => Uri.base.resolve('no_such_worker.dart.js');

Future<String> _callOnce(IRpcTransport transport) async {
  final caller = RpcCallerEndpoint(transport: transport);
  try {
    final response = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'EchoService',
          methodName: 'Echo',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'ping'.rpc,
        )
        .timeout(const Duration(seconds: 8));
    return response.value;
  } on TimeoutException {
    return 'HUNG';
  } catch (e) {
    return 'threw ${e.runtimeType}';
  }
}

void main() {
  test(
    'spawn() fails when the worker never boots',
    () async {
      final watch = Stopwatch()..start();

      await expectLater(
        RpcIsolateTransport.spawn(
          entrypoint: _unusedEntrypoint,
          workerUri: _missingWorker,
        ),
        throwsA(isA<StateError>()),
        reason:
            'nothing listened for the Worker error event, so both startup waits '
            'simply expired and spawn() handed back a transport wired to a '
            'worker that does not exist: health() said "healthy / Transport '
            'ready" and every call hung forever',
      );

      watch.stop();
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason:
            'the load failure is known immediately; waiting out both swallowed '
            '5s budgets took 10002ms to reach the wrong answer',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('startupTimeout is honoured', () async {
    // The parameter was accepted and never used -- 1s requested, 10002ms taken.
    // Asserted against an absolute bound, not against a second run: comparing
    // two independently timed runs would measure the machine, not the fix.
    final watch = Stopwatch()..start();
    await expectLater(
      RpcIsolateTransport.spawn(
        entrypoint: _unusedEntrypoint,
        workerUri: _missingWorker,
        startupTimeout: const Duration(seconds: 1),
      ),
      throwsA(isA<Object>()),
    );
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'a worker that dies after startup is noticed',
    () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: _unusedEntrypoint,
        workerUri: _realWorker,
      );
      addTearDown(spawned.kill);

      expect(await _callOnce(spawned.transport), 'echo:ping');

      final caller = RpcCallerEndpoint(transport: spawned.transport);
      await expectLater(
        caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'EchoService',
              methodName: 'Die',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'go'.rpc,
            )
            .timeout(const Duration(seconds: 8)),
        throwsA(isA<RpcStatusException>()),
        reason: 'the in-flight call must fail, not hang, when the worker dies',
      );

      await Future<void>.delayed(const Duration(seconds: 1));

      expect(spawned.transport.isClosed, isTrue);
      final health = await spawned.transport.health();
      expect(
        health.level,
        isNot(RpcHealthLevel.healthy),
        reason:
            'health() is what a supervisor polls; a transport whose worker is '
            'gone must not report healthy',
      );
      expect(await _callOnce(spawned.transport), startsWith('threw'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a healthy worker is unaffected',
    () async {
      // The startup path gained an error race and a real timeout; the ordinary
      // worker must still boot and serve, and must not be torn down by them.
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: _unusedEntrypoint,
        workerUri: _realWorker,
        startupTimeout: const Duration(seconds: 20),
      );
      addTearDown(spawned.kill);

      expect(await _callOnce(spawned.transport), 'echo:ping');
      expect(await _callOnce(spawned.transport), 'echo:ping');
      expect(spawned.transport.isClosed, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
