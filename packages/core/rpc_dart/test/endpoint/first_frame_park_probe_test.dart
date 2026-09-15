// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Does the FIRST frame of an upload park, on the shipped policy?
//
// `initialSendWindowBytes` is 64 KiB and arrived in 6.0.0 — 5.0.1 had no such
// parameter at all. A blob frame is 256 KiB, four times that, so on paper every
// upload's opening frame blocks until the peer's first grant. The consumer's
// server reported blobs short by exactly their opening frame, and single-frame
// blobs arriving as an empty stream, starting with the release that carried
// that bump.
//
// This reports rather than asserts: how long the opening frame waits, and
// whether everything still arrives. An assertion written before the measurement
// would only encode what I expect.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
const _frameBytes = 256 * 1024;

final class _Collector extends RpcResponderContract {
  _Collector({required this.startupDelay}) : super('Blob');

  final Duration startupDelay;
  final seen = <int>[];

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        // The real handler streams each frame into object storage before
        // asking for the next, and grants credit only as it consumes.
        await Future<void>.delayed(startupDelay);
        await for (final r in requests) {
          seen.add(r.value.length);
        }
        return RpcString('${seen.length}');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<void> _probe({
  required String label,
  required Duration startupDelay,
  required RpcSecurityPolicy policy,
  int count = 6,
}) async {
  final (clientT, serverT) = RpcChannelTransport.pair(policy: policy);
  final service = _Collector(startupDelay: startupDelay);
  final responder = RpcResponderEndpoint(transport: serverT);
  responder.registerServiceContract(service);
  responder.start();
  final caller = RpcCallerEndpoint(transport: clientT);

  // Sample the transport's own view: a non-zero waiter count is a sender
  // blocked on the window, which is the state under investigation.
  var peakWaiters = 0;
  var parkedMs = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final w = clientT.flowControlStateSizes['waiters'] ?? 0;
    if (w > 0) parkedMs += 20;
    if (w > peakWaiters) peakWaiters = w;
  });

  final filler = 'x' * _frameBytes;
  final requests = StreamController<RpcString>();
  final started = DateTime.now();
  final answer = caller.clientStream<RpcString, RpcString>(
    serviceName: 'Blob',
    methodName: 'Upload',
    requestCodec: _codec,
    responseCodec: _codec,
  )(requests.stream);
  for (var i = 0; i < count; i++) {
    requests.add(RpcString(filler));
  }
  await requests.close();

  String outcome;
  try {
    outcome =
        'answered ${(await answer.timeout(const Duration(seconds: 25))).value}';
  } catch (e) {
    outcome = 'FAILED ${e.runtimeType}';
  }
  sampler.cancel();
  final elapsed = DateTime.now().difference(started).inMilliseconds;

  print(
    '[$label] $outcome | handler got ${service.seen.length}/$count | '
    'peak waiters $peakWaiters | parked ~${parkedMs}ms | total ${elapsed}ms',
  );

  await caller.close();
  await responder.close();
  await clientT.close();
  await serverT.close();
}

void main() {
  test(
    'what the opening frame does on the shipped policy',
    () async {
      // Shipped defaults: 64 KiB initial window, 4 MiB stream window, 5s grace.
      await _probe(
        label: '6.0.0 defaults, handler reads at once',
        startupDelay: Duration.zero,
        policy: const RpcSecurityPolicy(),
      );
      await _probe(
        label: '6.0.0 defaults, handler sleeps 2s',
        startupDelay: const Duration(seconds: 2),
        policy: const RpcSecurityPolicy(),
      );
      await _probe(
        label: '6.0.0 defaults, handler sleeps 8s (past the grace)',
        startupDelay: const Duration(seconds: 8),
        policy: const RpcSecurityPolicy(),
      );
      // 5.0.1 had no initial send window. This is that shape.
      await _probe(
        label: '5.0.1 shape, no initial window, handler sleeps 8s',
        startupDelay: const Duration(seconds: 8),
        policy: const RpcSecurityPolicy(
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
