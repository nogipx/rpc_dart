// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// What `initialSendWindowBytes` buys, pinned — because a round once claimed it
// buys nothing and an owner decision was taken on that claim.
//
// The gap it covers is a LATENCY gap: credit exists only once a grant has
// arrived, so until then a sender is bounded by this and nothing else. On an
// in-process pair the grant is already there and the window looks inert, which
// is exactly how round 366 came to write "the park buys nothing that can be
// named". That is true of ONE large message — the gate admits on `credit > 0`,
// not on whether the message fits, so the first frame passes whatever the
// window is — and false of a burst, which is what the window is for.
//
// Measured over a real socket through toxiproxy at 50 ms RTT, a handler that
// never reads, 4 KiB frames, 3 s (round 380):
//
//     no initial window   40000 frames   156.25 MiB
//     64 KiB (shipped)     1039 frames     4.06 MiB
//     16 MiB              5108 frames     19.95 MiB
//
// This test keeps the SHAPE of that without the proxy: a loopback socket still
// has enough of a gap to separate "bounded" from "unbounded", which is the
// claim that was got wrong. The MiB figures above need the RTT and live in
// P-58's family, not here.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _frame = 4 * 1024;
const int _offered = 40000;

final class _Deaf extends RpcResponderContract {
  _Deaf() : super('Svc');

  @override
  void setup() {
    // Never reads, so no credit is ever returned: what gets out is what the
    // initial window allowed before the first grant.
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'deaf',
      handler: (reqs, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(minutes: 5));
        return 'x'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// How many frames the caller got out before it was throttled.
///
/// [until] is polled rather than slept to: this suite runs a thousand tests in
/// parallel, and counting after a fixed sleep measures how busy the machine was
/// — the unbounded arm once reported 16342 of 40000 in two seconds and failed
/// its own "is this rig reaching the regime" check. The BOUNDED arm still needs
/// a settling window, because there the property is that the number stops
/// rising; it gets one bounded by [settle].
Future<int> _flood(
  int port,
  RpcSecurityPolicy policy, {
  bool Function(int sent)? until,
  Duration settle = const Duration(seconds: 2),
}) async {
  var sent = 0;
  final body = 'x' * _frame;
  Stream<RpcString> produce() async* {
    for (var i = 0; i < _offered; i++) {
      sent = i + 1;
      yield body.rpc;
    }
  }

  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:$port'),
    policy: policy,
  );
  final caller = RpcCallerEndpoint(transport: client);
  unawaited(
    caller
        .clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'deaf',
          requestCodec: _codec,
          responseCodec: _codec,
        )(produce())
        .catchError((Object _) => 'x'.rpc),
  );

  if (until == null) {
    await Future<void>.delayed(settle);
  } else {
    // Generous: the question is whether it EVER runs away, not how fast.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline) && !until(sent)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  await caller.close().catchError((_) {});
  await client.close();
  return sent;
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;

  setUp(() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_Deaf()),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await http.close(force: true);
  });

  test('WITNESS: the shipped window bounds a flood a null window does not', () async {
    // Both arms on one server, one after the other, compared against each other
    // ONLY through the absolute bound below — tests.md item 3.
    final bounded = await _flood(http.port, const RpcSecurityPolicy());
    // Polled to the threshold: this arm only has to show it RUNS AWAY, and how
    // long that takes is the machine's business, not the library's.
    //
    // The threshold is 8000 frames (31 MiB) and NOT half the offered 40000,
    // because there is a SECOND ceiling above this one: with the initial window
    // off, the sender still stops at the connection window
    // (`flowControlConnectionWindowBytes`, 64 MiB by default) — observed at
    // exactly 16342 frames, 63.8 MiB, identical across runs and unchanged by
    // polling for twenty seconds. A threshold above that is unreachable by
    // construction, which reads as a flake and is not one.
    final unbounded = await _flood(
      http.port,
      const RpcSecurityPolicy(initialSendWindowBytes: null),
      until: (sent) => sent > 8000,
    );

    expect(
      unbounded,
      greaterThan(8000),
      reason:
          'with no initial window the caller should run away before the first '
          'grant; it sent only $unbounded of $_offered, so this rig is not '
          'reaching the regime and the comparison below means nothing',
    );
    expect(
      bounded,
      lessThan(_offered ~/ 4),
      reason:
          'the shipped 64 KiB initial window let $bounded of $_offered frames '
          'out before any grant arrived. It is what stops a burst outrunning '
          'the first grant — round 380 measured 156.25 MiB against 4.06 MiB at '
          '50 ms RTT — and B-47 claimed it buys nothing, which is true only of '
          'a single message larger than the window',
    );
  });

  test('GUARD: ordinary traffic does not wait on the window', () async {
    // The window must cost a small call nothing — it is sized so one round trip
    // of ordinary traffic never parks. Measured on the SENDING side, not on the
    // answer: this handler deliberately never replies, so waiting for a response
    // would measure the handler rather than the window.
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    final caller = RpcCallerEndpoint(transport: client);

    var pulled = 0;
    Stream<RpcString> few() async* {
      for (var i = 0; i < 8; i++) {
        pulled = i + 1;
        yield 'small'.rpc;
      }
    }

    unawaited(
      caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'deaf',
            requestCodec: _codec,
            responseCodec: _codec,
          )(few())
          .catchError((Object _) => 'x'.rpc),
    );

    // Poll to the outcome rather than sleeping to a verdict: eight tiny
    // messages are far inside a 64 KiB window and must all be taken.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) && pulled < 8) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      pulled,
      8,
      reason:
          'only $pulled of 8 small messages were taken from the producer: the '
          'initial window is throttling ordinary traffic, which is the cost '
          'the default is chosen to avoid',
    );
    await caller.close().catchError((_) {});
    await client.close();
  });
}
