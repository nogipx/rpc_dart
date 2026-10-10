// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The isolate member's worker. The peer behaviours that cannot be applied to
// a SendPort are produced here, by the worker itself: it serves, stays
// silent, exits mid-call, refuses to start, or answers with garbage.
//
// Talks to the host over one SendPort (`events` in customParams):
//   [kind, id, n]          a handler event, fed into the host's Probe
//   ['control', SendPort]  where the host sends requests to this worker
// and answers on the control port:
//   ['metrics', SendPort]  -> the endpoint's metrics, flattened to ints
//   ['die']                -> the worker exits at once

import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';

import 'contract.dart';
import 'peer.dart';

/// Worker behaviours, by name (customParams must be sendable).
abstract final class WorkerMode {
  static const serve = 'serve';

  /// The transport is up; no endpoint ever reads it.
  static const silent = 'silent';

  /// Serves, and exits the moment a handler starts.
  static const exitMidCall = 'exitMidCall';

  /// The entrypoint throws, so the worker never finishes starting.
  static const refuseToStart = 'refuseToStart';

  /// No endpoint: answers every call with a garbage payload, and sends
  /// garbage on stream ids the host never opened.
  static const garbage = 'garbage';
}

/// The entrypoint. Top-level, captures nothing.
void conformanceWorker(IRpcTransport transport, Map<String, dynamic> params) {
  final events = params['events'] as SendPort;
  final mode = params['mode'] as String;
  if (mode == WorkerMode.refuseToStart) {
    throw StateError('this worker refuses to start');
  }

  void emit(String kind, int id, int n) {
    events.send(<Object>[kind, id, n]);
    if (mode == WorkerMode.exitMidCall && kind == 'enter') Isolate.exit();
  }

  RpcResponderEndpoint? endpoint;
  switch (mode) {
    case WorkerMode.serve:
    case WorkerMode.exitMidCall:
      endpoint = RpcResponderEndpoint(transport: transport)
        ..registerServiceContract(ConformanceResponder(emit))
        ..start();
    case WorkerMode.garbage:
      _answerWithGarbage(transport);
    case WorkerMode.silent:
      break;
  }

  final control = ReceivePort();
  control.listen((Object? message) async {
    final m = message! as List<Object?>;
    switch (m[0]) {
      case 'metrics':
        (m[1]! as SendPort).send(await _metrics(endpoint, transport));
      case 'die':
        Isolate.exit();
    }
  });
  events.send(<Object>['control', control.sendPort]);
}

void _answerWithGarbage(IRpcTransport transport) {
  var seed = 100;
  // Unsolicited: payloads on even (server-opened) ids the host never saw.
  for (final id in const [2, 4, 6]) {
    transport.sendMessage(id, garbage(64, seed: seed++)).ignore();
  }
  transport.incomingMessages.listen((message) {
    if (message.metadata == null || message.methodPath == null) return;
    final id = message.streamId;
    transport
        .sendMetadata(id, RpcMetadata.forServerInitialResponse())
        .then((_) => transport.sendMessage(id, garbage(256, seed: seed++)))
        .then((_) => transport.sendMessage(id, garbage(256, seed: seed++)))
        .then((_) => transport.finishSending(id))
        .catchError((Object _) {})
        .ignore();
  }, onError: (Object _) {});
}

Future<Map<String, int>> _metrics(
  RpcResponderEndpoint? endpoint,
  IRpcTransport transport,
) async {
  final out = <String, int>{};
  if (endpoint != null) {
    for (final e in endpoint.collectEndpointMetrics().entries) {
      if (e.value is int) out[e.key] = e.value! as int;
    }
  }
  final health = await transport.health();
  for (final e in health.details.entries) {
    if (e.value is int) out['transport.${e.key}'] = e.value! as int;
  }
  if (transport is RpcChannelTransport) {
    for (final e in transport.flowControlStateSizes.entries) {
      out['fc.${e.key}'] = e.value;
    }
  }
  return out;
}
