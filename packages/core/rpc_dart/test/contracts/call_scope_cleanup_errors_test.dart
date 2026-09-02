// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallScope is the documented per-call cleanup API: a handler registers
// releases with `context.callScope?.onDispose(...)` and the server closes the
// scope when the call ends. Two defects on that path, measured:
//
//   disposer after the throwing one ran : true
//   uncaught async errors               : 0
//   log records emitted                 : 0     <- failure vanished entirely
//
//   events received                     : [1]
//   uncaught async errors               : 2     <- track() could kill the isolate
//       StateError: Bad state: cancel failed
//       StateError: Bad state: cancel failed
//
// close() ran disposers under a bare `catch (_) {}`, so a handler's own cleanup
// failing -- a database handle that would not release, a file that would not
// close -- left no trace anywhere: no log, no error, nothing to notice.
//
// track() was worse. It dropped the future from sub.cancel() in TWO places, the
// controller's onCancel and the disposer, and cancelling a stream runs user
// code that may throw. An unhandled async error in the root zone terminates the
// isolate, so a tracked stream whose cleanup failed could take a server down.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Runs [body] in a guarded zone and returns the errors that escaped.
Future<List<Object>> _uncaughtFrom(Future<void> Function() body) async {
  final errors = <Object>[];
  await runZonedGuarded(body, (e, _) => errors.add(e));
  // Let anything scheduled during teardown surface.
  await Future<void>.delayed(const Duration(milliseconds: 150));
  return errors;
}

/// A scope whose log records land in [logs].
RpcCallScope _scopeLogging(RingBufferOutput logs, LogController controller) {
  return RpcCallScope(
    context: RpcContext.empty().withLog(controller.scope('call')),
  );
}

void main() {
  group('a disposer that throws', () {
    test('is reported instead of vanishing', () async {
      final logs = RingBufferOutput();
      final controller = LogController(outputs: [logs]);
      final scope = _scopeLogging(logs, controller);

      scope.onDispose(() => throw StateError('db handle would not release'));
      await scope.close();

      final errors = logs.entries
          .whereType<LogEvent>()
          .where((e) => e.level == RpcLogLevel.error)
          .toList();
      expect(
        errors,
        isNotEmpty,
        reason: 'a failing disposer left no trace at all',
      );
      expect(errors.first.message, contains('disposer failed'));

      controller.dispose();
    });

    test('does not strand the disposers after it', () async {
      // The reason the throw is swallowed at all: every disposer must run.
      final ran = <String>[];
      final scope = RpcCallScope();

      scope.onDispose(() => ran.add('first'));
      scope.onDispose(() => throw StateError('middle blew up'));
      scope.onDispose(() => ran.add('last'));

      await scope.close();

      // LIFO: last registered runs first.
      expect(ran, ['last', 'first']);
    });

    test('does not escape as an unhandled async error', () async {
      final errors = await _uncaughtFrom(() async {
        final scope = RpcCallScope();
        scope.onDispose(() => throw StateError('boom'));
        await scope.close();
      });
      expect(errors, isEmpty);
    });
  });

  group('track() with a stream whose cancel rejects', () {
    test('does not produce unhandled async errors', () async {
      final errors = await _uncaughtFrom(() async {
        final scope = RpcCallScope();
        final source = StreamController<int>(
          onCancel: () async => throw StateError('cancel failed'),
        );
        source.add(1);

        final got = <int>[];
        scope.track(source.stream).listen(got.add, onError: (Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await scope.close();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(got, [1], reason: 'events before close should still arrive');
      });

      expect(
        errors,
        isEmpty,
        reason:
            '${errors.length} unhandled async error(s) escaped; in the '
            'root zone that terminates the isolate',
      );
    });

    test('reports the failed cancel when the scope can log', () async {
      final logs = RingBufferOutput();
      final controller = LogController(outputs: [logs]);
      final scope = _scopeLogging(logs, controller);

      final source = StreamController<int>(
        onCancel: () async => throw StateError('cancel failed'),
      );
      source.add(1);
      scope.track(source.stream).listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await scope.close();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        logs.entries.whereType<LogEvent>().where(
          (e) => e.message.contains('failed to cancel'),
        ),
        isNotEmpty,
      );

      controller.dispose();
    });
  });

  group('the ordinary paths are unchanged', () {
    test('a well-behaved tracked stream still delivers and closes', () async {
      final scope = RpcCallScope();
      final source = StreamController<int>();

      final got = <int>[];
      var done = false;
      scope.track(source.stream).listen(got.add, onDone: () => done = true);

      source.add(1);
      source.add(2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await scope.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(got, [1, 2]);
      expect(done, isTrue, reason: 'closing the scope must end the stream');
      await source.close();
    });

    test('close() still completes done and is idempotent', () async {
      final scope = RpcCallScope();
      var count = 0;
      scope.onDispose(() => count++);

      await scope.close();
      await scope.close();

      expect(count, 1, reason: 'disposers must run exactly once');
      expect(scope.isClosed, isTrue);
      await scope.done;
    });
  });
}
