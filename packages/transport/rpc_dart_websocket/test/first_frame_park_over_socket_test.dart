// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Does a sender ever park on the window over a REAL socket with a REAL delay?
//
// The same question answered in-process came back "never": with
// `RpcChannelTransport.pair()` the peer's grant is already there by the time
// the next send asks, so no sender ever waits. That answer is worth nothing for
// the field, where a grant costs a round trip.
//
// So: a genuine WebSocket, and a relay in the middle that holds every byte for
// a fixed delay in both directions — the cheapest honest RTT there is, and no
// Docker in the loop. The payload is the one that matters: 256 KiB a frame, the
// size `ChunkedBlobIO` cuts, against the 64 KiB initial send window that
// 6.0.0 introduced and 5.0.1 did not have.
//
// It reports rather than asserts. The point is to find out whether the parked
// state is reachable at all on the shipping path; an assertion would only
// record what I expected to find.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);
const _frameBytes = 256 * 1024;

final class _Collector extends RpcResponderContract {
  _Collector({required this.perFrameDelay}) : super('Blob');

  /// Stands in for writing each frame to object storage before asking for the
  /// next one — which is when the real handler returns credit.
  final Duration perFrameDelay;
  final seen = <int>[];

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        await for (final r in requests) {
          await Future<void>.delayed(perFrameDelay);
          seen.add(r.value.length);
        }
        return RpcString('${seen.length}');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Forwards TCP both ways, holding every chunk for [delay] first.
///
/// Deliberately dumb: no bandwidth ceiling, no reordering. Latency alone is the
/// variable, because latency alone is what separates a grant that has already
/// arrived from one that has not.
Future<ServerSocket> _delayingRelay({
  required int upstreamPort,
  required Duration delay,
}) async {
  final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  relay.listen((client) async {
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      upstreamPort,
    );
    void pipe(Socket from, Socket to) {
      from.listen(
        (data) => Timer(delay, () {
          try {
            to.add(data);
          } catch (_) {}
        }),
        onDone: () => Timer(delay, () {
          try {
            to.close();
          } catch (_) {}
        }),
        onError: (_) {},
      );
    }

    pipe(client, upstream);
    pipe(upstream, client);
  });
  return relay;
}

Future<void> _probe({
  required String label,
  required Duration rtt,
  required Duration perFrameDelay,
  required RpcSecurityPolicy policy,
  int count = 8,
}) async {
  final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final connections = StreamController<WebSocketChannel>();
  httpServer.listen((req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    connections.add(IOWebSocketChannel(ws));
  });

  final service = _Collector(perFrameDelay: perFrameDelay);
  final server = RpcWebSocketServer(
    connections: connections.stream,
    policy: policy,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(service);
      endpoint.start();
    },
  );
  await server.start();

  final relay = await _delayingRelay(
    upstreamPort: httpServer.port,
    delay: Duration(microseconds: rtt.inMicroseconds ~/ 2),
  );

  final channel = WebSocketChannel.connect(
    Uri.parse('ws://127.0.0.1:${relay.port}'),
  );
  await channel.ready;
  // The same three layers `RpcWebSocketCallerTransport` composes
  // (RpcWebSocketChannel -> RpcChannelTransport), built by hand only so the
  // probe can read the transport's own flow-control counters — `_inner` is
  // private, and a probe that cannot see the state it is probing is theatre.
  final transport = RpcChannelTransport.fromChannel(
    channel: RpcWebSocketChannel(channel),
    isClient: true,
    policy: policy,
  );
  final caller = RpcCallerEndpoint(transport: transport);

  var peakWaiters = 0;
  var parkedMs = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final w = transport.flowControlStateSizes['waiters'] ?? 0;
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
        'answered ${(await answer.timeout(const Duration(seconds: 60))).value}';
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
  await server.stop();
  await relay.close();
  await httpServer.close(force: true);
  await connections.close();
}

void main() {
  test(
    'a sender over a real, latent socket',
    () async {
      for (final rtt in [
        Duration.zero,
        const Duration(milliseconds: 40),
        const Duration(milliseconds: 200),
      ]) {
        await _probe(
          label: '6.0.0 defaults, rtt ${rtt.inMilliseconds}ms',
          rtt: rtt,
          perFrameDelay: const Duration(milliseconds: 150),
          policy: const RpcSecurityPolicy(),
        );
      }
      // The case that matters most: a blob so small that the PARKED frame is the
      // last one, so the stream ends while it is still waiting. A one-frame blob
      // is the shape the consumer's server reported as "the stream carried no
      // frames at all".
      for (final count in [1, 2, 3]) {
        await _probe(
          label: '6.0.0 defaults, rtt 200ms, $count frame(s)',
          rtt: const Duration(milliseconds: 200),
          perFrameDelay: const Duration(milliseconds: 150),
          policy: const RpcSecurityPolicy(),
          count: count,
        );
      }
      for (final count in [1, 2, 3]) {
        await _probe(
          label: '5.0.1 shape,   rtt 200ms, $count frame(s)',
          rtt: const Duration(milliseconds: 200),
          perFrameDelay: const Duration(milliseconds: 150),
          policy: const RpcSecurityPolicy(
            initialSendWindowBytes: null,
            initialSendWindowGrace: null,
          ),
          count: count,
        );
      }

      // The 5.0.1 shape: no initial send window existed at all.
      await _probe(
        label: '5.0.1 shape, rtt 200ms',
        rtt: const Duration(milliseconds: 200),
        perFrameDelay: const Duration(milliseconds: 150),
        policy: const RpcSecurityPolicy(
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
