// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Per-stream flow-control bookkeeping must return to zero when calls end, and
// an ABANDONED upload is still an ordinary call.
//
// `_fcForget` clears the entry at teardown, and then a late grant for that id
// put it straight back -- ordinary, not hostile: the peer credits what it
// consumed or discarded, and that can cross our own teardown. Nothing removes
// it a second time. Measured with a handler that consumes nothing, so the
// sender parks and the call is abandoned:
//
//   handler drains (sender never parks) : 30 calls -> sendCredit  0
//   handler consumes nothing            : 30 calls -> sendCredit 30
//
// One entry per call, linear (6 calls gave 6). The map is capped, so this never
// grows without bound; what it does instead is quieter. Once the cap is full of
// dead ids, new ones are refused, so no later stream is seeded and
// `initialSendWindowBytes` stops applying to any of them -- and that seed is
// what bounds a sender before the peer's first grant, worth 156.25 MiB against
// 4.05 MiB over a 20 ms link.
//
// Pinned by instrumenting both hops: GRANT 1, GRANT 1, FORGET 1 x4, GRANT 1 --
// the last one lands after the id is gone. An earlier theory, that the sender
// woken by `_fcForget` re-seeds through `_fcTryConsume`, was measured and
// disproven: closing that path left the number at exactly 30.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _window = 64 * 1024;
const int _messageBytes = 4 * 1024;
const int _offered = 2000; // 8 MiB, 128x the window
const int _calls = 10;

/// Per-test state the handler captures, so a handler left running by an earlier
/// test cannot be mistaken for this one's.
final class _Run {
  int consumed = 0;
}

final class _Contract extends RpcResponderContract {
  _Contract(this.run, this.drains) : super('Svc');

  final _Run run;
  final bool drains;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        if (drains) {
          await for (final _ in requests) {
            run.consumed++;
          }
          return 'drained'.rpc;
        }
        // Consumes nothing and waits, so the client fills its window and parks
        // for real before the answer arrives.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return 'early'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<Map<String, int>> _drive({required bool drains}) async {
  final run = _Run();
  const policy = RpcSecurityPolicy(
    flowControlWindowBytes: _window,
    flowControlConnectionWindowBytes: 64 * _window,
  );
  final (clientT, serverT) = RpcChannelTransport.pair(policy: policy);
  final caller = RpcCallerEndpoint(transport: clientT);
  final responder = RpcResponderEndpoint(transport: serverT);
  responder.registerServiceContract(_Contract(run, drains));
  responder.start();

  final body = 'x' * _messageBytes;
  for (var i = 0; i < _calls; i++) {
    Stream<RpcString> requests() async* {
      for (var j = 0; j < _offered; j++) {
        yield body.rpc;
      }
    }

    final call = caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Upload',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    try {
      await call(requests()).timeout(const Duration(seconds: 20));
    } catch (_) {}
    // Teardown runs in the pipeline's cleanup, not synchronously with the
    // response, so give it a turn before reading the counters.
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  final sizes = Map<String, int>.from(clientT.flowControlStateSizes);
  await caller.close();
  await responder.close();
  await clientT.close();
  await serverT.close();
  return sizes;
}

void main() {
  test(
    'an abandoned upload leaves no per-stream credit behind',
    () async {
      // WITNESS. Without the liveness gate on a late grant this is $_calls.
      final sizes = await _drive(drains: false);
      expect(
        sizes['sendCredit'],
        0,
        reason:
            '$_calls abandoned uploads left ${sizes['sendCredit']} send-credit '
            'entries for streams that have ended; the map is capped, so the cost '
            'is that the initial send window stops seeding new streams once it '
            'fills',
      );
      expect(sizes['waiters'], 0);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'GUARD: a drained upload was already clean',
    () async {
      // The control, and the paired "a valid case is not broken": these calls
      // never park, so they never took the late-grant path at all. If this ever
      // goes non-zero the mechanism is a different one.
      final sizes = await _drive(drains: true);
      expect(sizes['sendCredit'], 0);
      expect(sizes['waiters'], 0);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'GUARD: every counter returns to zero, not just this one',
    () async {
      // The whole map, so a fix that trades one leaking counter for another is
      // caught here rather than in a later round.
      final sizes = await _drive(drains: false);
      for (final entry in sizes.entries) {
        expect(
          entry.value,
          0,
          reason: '${entry.key} was left at ${entry.value} after $_calls calls',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
