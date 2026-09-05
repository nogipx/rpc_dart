// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `spawn()` returns (transport, kill), and everything it acquired -- the
// isolate, the error port and the exit port -- used to be released by kill()
// alone. But the thing it hands back is an IRpcTransport, and
// `RpcEndpointBase.close()` closes the transport it was given, so an
// application that wires the spawned transport into an endpoint and closes the
// endpoint reaches close() and never kill().
//
// Measured, with the worker beating on a port so "still running" is observable:
//
//   teardown via transport.close() : beats after teardown 12, host process
//                                    NEVER EXITED (killed at 15s)
//   teardown via kill()            : beats after teardown 0, host process
//                                    exited in 809 ms
//
// A whole isolate -- thread and heap -- per connection, plus two open
// ReceivePorts keeping the host's event loop alive so the process could not end.
//
// Every existing test in this package tears down with kill(), which is exactly
// why a green suite never saw it. The WEB sibling was the tell: its channel
// closes through isolate_manager's controller, which terminates the Worker
// there, so the VM variant was the odd one out.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

/// Beats on [params]'s port forever, so the isolate never runs out of work --
/// which is the realistic case. A worker holding a timer, a subscription or a
/// socket does not wind down just because its ports were closed; only a kill
/// reclaims it.
@pragma('vm:entry-point')
void beatingWorker(IRpcTransport transport, Map<String, dynamic> params) {
  final beat = params['beat'] as SendPort;
  Timer.periodic(const Duration(milliseconds: 100), (_) => beat.send(1));
}

final _codec = RpcCodec(RpcString.fromJson);

@pragma('vm:entry-point')
void echoWorker(IRpcTransport transport, Map<String, dynamic> params) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  endpoint.registerServiceContract(_EchoContract());
  endpoint.start();
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async =>
          'echo-${request.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Beats observed in a sample window after tearing the connection down with
/// [useKill]. Alive is ~12 per window; dead is 0.
Future<int> beatsAfterTeardown({required bool useKill}) async {
  var beats = 0;
  final port = ReceivePort();
  final sub = port.listen((_) => beats++);

  final spawned = await RpcIsolateTransport.spawn(
    entrypoint: beatingWorker,
    customParams: {'beat': port.sendPort},
  );
  await Future<void>.delayed(const Duration(milliseconds: 400));
  expect(beats, greaterThan(0), reason: 'the worker never started beating');

  if (useKill) {
    spawned.kill();
  } else {
    await spawned.transport.close();
  }

  // Drain first: a beat already queued on the port when the isolate died is
  // still delivered, and counting it would read as "still running".
  await Future<void>.delayed(const Duration(milliseconds: 300));
  beats = 0;
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  await sub.cancel();
  port.close();
  return beats;
}

void main() {
  test(
    'transport.close() stops the worker isolate',
    () async {
      expect(
        await beatsAfterTeardown(useKill: false),
        0,
        reason:
            'the standard lifecycle call left the isolate running: a thread and a '
            'heap leaked per connection, reclaimable only through kill()',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: kill() still stops the worker isolate',
    () async {
      expect(await beatsAfterTeardown(useKill: true), 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: the isolate stays alive while the transport is in use',
    () async {
      // The load-bearing guard. Tearing down on channel-close is only correct
      // if nothing closes the channel early -- a fix that killed the worker
      // eagerly would still pass the witness above.
      final spawned = await RpcIsolateTransport.spawn(entrypoint: echoWorker);
      addTearDown(() async => spawned.kill());

      final caller = RpcCallerEndpoint(transport: spawned.transport);
      for (var i = 0; i < 5; i++) {
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: '$i'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 10));
        expect(r.value, 'echo-$i');
      }
      await caller.close().catchError((Object _) {});
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: closing twice, and closing after kill(), are no-ops',
    () async {
      final spawned = await RpcIsolateTransport.spawn(entrypoint: echoWorker);
      await spawned.transport.close();
      await spawned.transport.close();
      spawned.kill();
      spawned.kill();
      expect(spawned.transport.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('the host process ends after teardown', () {
    /// Runs the support script and reports how it finished. The observable is
    /// the child's own exit, so this is a subprocess rather than an in-process
    /// assertion: an open ReceivePort keeps the event loop alive, and nothing
    /// inside the same isolate can see that directly.
    Future<String> outcome(String mode) async {
      final script = Directory.current.path.endsWith('rpc_dart_isolate')
          ? 'test/support/exits_after_close.dart'
          : 'packages/transport/rpc_dart_isolate/test/support/exits_after_close.dart';
      final proc = await Process.start(Platform.resolvedExecutable, [
        'run',
        script,
        mode,
      ]);
      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.drain<void>());
      final code = await proc.exitCode
          .timeout(const Duration(seconds: 20))
          .catchError((Object _) => -999);
      if (code == -999) {
        proc.kill(ProcessSignal.sigkill);
        return 'still running';
      }
      return 'exited $code';
    }

    test('after transport.close()', () async {
      expect(
        await outcome('close'),
        'exited 0',
        reason:
            'errorPort and exitPort stayed open, so the host event loop never '
            'drained and the process could not end',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('GUARD: after kill()', () async {
      expect(await outcome('kill'), 'exited 0');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
