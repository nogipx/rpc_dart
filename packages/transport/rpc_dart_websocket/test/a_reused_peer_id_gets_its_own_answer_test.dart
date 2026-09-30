// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer client answers a call, the socket drops mid-answer, and the server's
// fresh endpoint numbers its next stream from the bottom -- the same id the
// parked handler still holds. Three things then happen on that number, and each
// one is a separate mechanism:
//
//   the old stream state is still there, so the new call's opening frame reads as
//   a repeat and is ignored;
//   the parked handler's answer goes out on the id and is delivered to the new
//   caller;
//   the old call's tail cleanup tears down whatever state the id names now.
//
// The witness is what the second caller receives. Nothing about a stream id makes
// it unique for longer than one connection.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Registered on the CLIENT. Each call parks until its own gate opens, so one
/// answer can be held across a reconnect.
final class _Answering extends RpcPeerContract {
  _Answering(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  final gates = <String, Completer<void>>{};
  final started = <String>[];
  final cancelled = <String>[];

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Ask',
      handler: (request, {RpcContext? context}) async {
        final what = request.value;
        started.add(what);
        await gates.putIfAbsent(what, Completer<void>.new).future;
        if (context?.cancellationToken?.isCancelled ?? false) {
          cancelled.add(what);
        }
        return 'answered $what'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  void open(String what) {
    final gate = gates[what];
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

final class _Asking extends RpcPeerContract {
  _Asking(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  @override
  void setup() {}

  Future<String> ask(String what) async {
    final reply = await callUnary<RpcString, RpcString>(
      methodName: 'Ask',
      request: what.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return reply.value;
  }
}

/// Polled, not slept on: the frames cross a real socket, so how long each step
/// takes is not this test's to assume.
Future<bool> _pollFor(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

/// For the steps that must happen for the run to mean anything at all.
Future<void> _waitFor(bool Function() condition, String what) async {
  if (await _pollFor(condition)) return;
  throw StateError('timed out waiting for $what');
}

/// Collects the client pipeline's own warnings.
///
/// The decisive one cannot be read from the caller's result: a new call IGNORED
/// as a repeat opening frame and a new call served late look the same from
/// outside, and only the first leaves a record.
class _Warnings extends LogController {
  final lines = <String>[];

  @override
  void add(LogRecord record) {
    if (record is LogEvent && record.level == RpcLogLevel.warning) {
      lines.add(record.message);
    }
    super.add(record);
  }

  List<String> get repeatOpeningFrames =>
      lines.where((l) => l.contains('repeat opening frame')).toList();
}

typedef _Run = ({
  String secondGot,
  List<int> openedOn,
  List<String> cancelled,
  List<String> stray,
  List<String> repeatOpeningFrames,
});

/// Runs one caller through a reconnect and reports what it got.
///
/// [reconnect] drops the socket while the first answer is parked; without it both
/// calls run on one connection and the peer's ids cannot collide.
/// [finishFirstEarly] lets the parked answer out BEFORE the id is reused, so no
/// stale call is left to interfere.
///
/// Whole body inside one guarded zone, teardown included: a caller on a socket
/// that went away raises into the root zone from a detached future, which is a
/// separate defect from this one and would otherwise fail this test instead of
/// being reported by it.
Future<_Run> _run({required bool reconnect, bool finishFirstEarly = false}) {
  final stray = <String>[];
  final done = Completer<_Run>();

  runZonedGuarded(
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final built = <RpcPeerEndpoint>[];
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onPeerEndpointCreated: built.add,
      );
      await server.start();

      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final warnings = _Warnings();
      final clientPeer = RpcPeerEndpoint(
        transport: transport,
        logger: warnings,
      );
      final answering = _Answering(clientPeer);
      clientPeer.registerServiceContract(answering);
      clientPeer.start();

      // The id the PEER chose, read where it is observable.
      final openedOn = <int>[];
      final watcher = transport.incomingMessages.listen((m) {
        if (m.methodPath != null) openedOn.add(m.streamId);
      });

      var got = 'not reached';
      try {
        await _waitFor(() => built.isNotEmpty, 'the first server endpoint');
        final first = _Asking(built[0]);
        // The handler is attached HERE, not where the result is read. This call
        // is expected to fail -- its socket goes away under it -- and a Future
        // that completes with an error nobody is listening to YET is reported as
        // unhandled, which is a property of the rig and not of the library.
        final firstCall = first
            .ask('one')
            .catchError((Object e) => 'the first caller lost its socket: $e');
        await _waitFor(
          () => answering.started.contains('one'),
          'the first handler',
        );

        if (finishFirstEarly) {
          answering.open('one');
          await firstCall.timeout(const Duration(seconds: 5));
        }

        final _Asking second;
        if (reconnect) {
          await transport.reconnect();
          await _waitFor(() => built.length > 1, 'the second server endpoint');
          second = _Asking(built[1]);
        } else {
          second = first;
        }

        final secondCall = second.ask('two');
        // NOT fatal: the second handler never starting is one of the outcomes
        // under test, and failing here would throw away the records that say
        // WHY it did not.
        await _pollFor(() => answering.started.contains('two'));

        // The parked answer goes out FIRST, onto whatever connection is current.
        answering.open('one');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        answering.open('two');

        try {
          got = await secondCall.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          got = 'TIMEOUT';
        } catch (e) {
          got = e is RpcStatusException ? 'status ${e.statusCode}' : 'error $e';
        }
        await firstCall.timeout(const Duration(seconds: 5));
      } finally {
        // Every parked handler released first: closing the endpoint under one
        // cancels it, and that throw reaches the zone with no caller left.
        for (final key in answering.gates.keys.toList()) {
          answering.open(key);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await watcher.cancel();
        await clientPeer.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
        await server.dispose().catchError((Object _) {});
        await http.close(force: true);
      }

      if (!done.isCompleted) {
        done.complete((
          secondGot: got,
          openedOn: openedOn,
          cancelled: answering.cancelled,
          stray: stray,
          repeatOpeningFrames: warnings.repeatOpeningFrames,
        ));
      }
    },
    (Object error, StackTrace st) {
      stray.add('$error');
      if (!done.isCompleted) done.completeError(error, st);
    },
  );

  return done.future;
}

void main() {
  test(
    'a reused peer id gets its OWN answer, not the parked one',
    () async {
      final r = await _run(reconnect: true);

      expect(
        r.openedOn,
        [2, 2],
        reason:
            'the premise: the server endpoint is fresh, so it numbers from the '
            'bottom and the second call lands on the first one\'s id',
      );
      expect(
        r.repeatOpeningFrames,
        isEmpty,
        reason:
            'the new call opened a stream the pipeline was still holding for '
            'the old one, so its opening frame read as a repeat and the call '
            'was never dispatched',
      );
      expect(
        r.secondGot,
        'answered two',
        reason:
            'the parked handler answered on this id first, and that answer '
            'belongs to a caller on a connection that no longer exists',
      );
      expect(
        r.stray,
        isEmpty,
        reason: 'nothing here may reach the root zone, on either side',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the dropped connection tells its handler, so the answer is not written',
    () async {
      // The other half of the same fix: without the notice the handler keeps
      // running with nowhere to send, and the pipeline still holds its stream
      // state -- which is what made the new call read as a repeat opening frame.
      final r = await _run(reconnect: true);

      expect(
        r.cancelled,
        contains('one'),
        reason:
            'the handler is the only place that can stop, and a token nothing '
            'cancels is a handler answering into a dead socket',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD without a reconnect the ids differ and both callers are served',
    () async {
      final r = await _run(reconnect: false);

      expect(r.openedOn, [2, 4]);
      expect(r.secondGot, 'answered two');
      expect(r.cancelled, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD a reconnect with nothing left parked serves the reused id',
    () async {
      final r = await _run(reconnect: true, finishFirstEarly: true);

      expect(r.openedOn, [2, 2]);
      expect(r.secondGot, 'answered two');
      expect(
        r.cancelled,
        isEmpty,
        reason: 'the first call was over before the drop, so nothing to cancel',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
