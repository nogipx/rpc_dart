// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The per-stream buffer bound multiplies by the stream count: a peer ignoring
// flow control parks a full stream's worth on every stream it opens. The
// connection total is the connection window, which an honest peer cannot
// exceed.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
final _chunk = ('z' * 1024).rpc;

/// ~128 KiB across the connection, against ~1 KiB messages and a per-stream
/// ceiling that alone would admit 1024 of them on each stream.
const _connectionWindow = 128 * 1024;

final class _State {
  int consumed = 0;
  int produced = 0;
  bool stopProducing = false;
  final hold = Completer<void>();
  final entered = Completer<void>();
}

final class _Contract extends RpcResponderContract {
  _Contract(this.s) : super('Svc');

  final _State s;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {
          s.consumed++;
          await s.hold.future;
        }
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final _ in reqs) {
          s.consumed++;
          await s.hold.future;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'held',
      handler: (req, {RpcContext? context}) async {
        if (!s.entered.isCompleted) s.entered.complete();
        await s.hold.future;
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'counts',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
        }
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Stream<RpcString> _gen(_State s, int n) async* {
  for (var i = 0; i < n; i++) {
    if (s.stopProducing) return;
    s.produced++;
    yield _chunk;
    if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
  }
}

/// Opens [streams] calls of [method] that each read one message and park,
/// releases them once the producers stop being pulled, and counts what they
/// drain — the responder side's holding. Then, on the SAME connection, runs one
/// ordinary call, which a charge left behind by the flood would refuse.
Future<({int retained, int errors, String after})> _flood({
  required String method,
  required int streams,
  required bool peerHonoursWindow,
}) async {
  final s = _State();
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: peerHonoursWindow
        ? const RpcSecurityPolicy()
        : const RpcSecurityPolicy(
            flowControlWindowBytes: null,
            flowControlConnectionWindowBytes: null,
            initialSendWindowBytes: null,
          ),
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: const RpcSecurityPolicy(
      flowControlConnectionWindowBytes: _connectionWindow,
    ),
  );
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract(s))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);

  var errors = 0;
  final calls = <Future<void>>[];
  for (var i = 0; i < streams; i++) {
    final requests = _gen(s, 500);
    final bidi = method == 'bidi' || (method == 'mixed' && i.isEven);
    calls.add(
      bidi
          ? caller
                .bidirectionalStream<RpcString, RpcString>(
                  serviceName: 'Svc',
                  methodName: 'bidi',
                  requests: requests,
                  requestCodec: _codec,
                  responseCodec: _codec,
                )
                .drain<void>()
                .then<void>((_) {}, onError: (Object _) => errors++)
          : caller
                .clientStream<RpcString, RpcString>(
                  serviceName: 'Svc',
                  methodName: 'upload',
                  requestCodec: _codec,
                  responseCodec: _codec,
                )(requests)
                .then<void>((_) {}, onError: (Object _) => errors++),
    );
  }

  var lastProduced = -1;
  while (s.produced != lastProduced) {
    lastProduced = s.produced;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  s.stopProducing = true;
  final before = s.consumed;
  s.hold.complete();
  var last = -1;
  while (s.consumed != last) {
    last = s.consumed;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final retained = s.consumed - before;
  await Future.wait(
    calls,
  ).timeout(const Duration(seconds: 10), onTimeout: () => []);

  String after;
  try {
    final fresh = StreamController<RpcString>();
    final answer = caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'counts',
      requestCodec: _codec,
      responseCodec: _codec,
    )(fresh.stream);
    for (var i = 0; i < 200; i++) {
      fresh.add(_chunk);
    }
    await fresh.close();
    after = (await answer.timeout(const Duration(seconds: 10))).value;
  } catch (e) {
    after = e.toString().split('\n').first;
  }

  await caller.close();
  await responder.close();
  await client.close();
  await server.close();
  return (retained: retained, errors: errors, after: after);
}

void main() {
  // 8 streams x the per-stream ceiling would be ~8 MiB; the connection holds
  // at most ~128 KiB, which is ~120 of these messages.
  const ceiling = _connectionWindow ~/ 1024;

  test(
    'client-streams on one connection hold no more than its window',
    () async {
      final r = await _flood(
        method: 'upload',
        streams: 8,
        peerHonoursWindow: false,
      );
      expect(r.retained, lessThanOrEqualTo(ceiling), reason: '$r');
      expect(r.errors, greaterThan(0), reason: 'nothing was refused: $r');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'bidi streams on one connection hold no more than its window',
    () async {
      final r = await _flood(
        method: 'bidi',
        streams: 8,
        peerHonoursWindow: false,
      );
      expect(r.retained, lessThanOrEqualTo(ceiling), reason: '$r');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'client-streams and bidi streams together hold no more than its window',
    () async {
      // The two shapes buffer in different layers; each counting only its own
      // would let a peer mixing them hold the window once per layer.
      final r = await _flood(
        method: 'mixed',
        streams: 8,
        peerHonoursWindow: false,
      );
      expect(r.retained, lessThanOrEqualTo(ceiling), reason: '$r');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'after the flood the connection serves an ordinary call',
    () async {
      // Every charge the refused streams held must come back at teardown, or the
      // connection refuses everything from here on.
      final r = await _flood(
        method: 'upload',
        streams: 8,
        peerHonoursWindow: false,
      );
      expect(r.after, '200', reason: '$r');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a unary torn down with frames still held returns them',
    () async {
      // Frames sent while a unary handler runs are charged and never taken; only
      // the stream's teardown can give them back. Fill the connection that way,
      // let the refusal end the call, then make an ordinary one.
      final s = _State();
      final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
      final client = RpcChannelTransport(
        channel: clientCh,
        isClient: true,
        policy: const RpcSecurityPolicy(
          flowControlWindowBytes: null,
          flowControlConnectionWindowBytes: null,
          initialSendWindowBytes: null,
        ),
      );
      final server = RpcChannelTransport(
        channel: serverCh,
        isClient: false,
        policy: const RpcSecurityPolicy(
          flowControlConnectionWindowBytes: _connectionWindow,
        ),
      );
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Contract(s))
        ..start();
      final caller = RpcCallerEndpoint(transport: client);

      final id = client.createStream();
      String? status;
      final sub = client.getMessagesForStream(id).listen((m) {
        status ??= m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      }, onError: (Object _) {});
      await client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'held'),
      );
      final frame = RpcMessageFrame.encode(_codec.serialize(_chunk));
      await client.sendMessage(id, frame);
      await s.entered.future.timeout(const Duration(seconds: 5));
      // Past the connection total, so the stream is refused and torn down while
      // holding all of it.
      for (var i = 0; i < ceiling + 16 && status == null; i++) {
        await client.sendMessage(id, frame);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (status == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // INTERNAL since round 637: the first frame after the request is a second
      // request, refused at once, so the stream is torn down holding only the
      // request -- which is still what must come back.
      expect(status, '${RpcStatus.internal}');
      s.hold.complete();

      final fresh = StreamController<RpcString>();
      final answer = caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'counts',
        requestCodec: _codec,
        responseCodec: _codec,
      )(fresh.stream);
      for (var i = 0; i < 64; i++) {
        fresh.add(_chunk);
      }
      await fresh.close();
      String after;
      try {
        after = (await answer.timeout(const Duration(seconds: 10))).value;
      } catch (e) {
        after = e.toString().split('\n').first;
      }
      expect(after, '64', reason: 'the finished unary kept its charge');

      await sub.cancel();
      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: an honest peer is never refused',
    () async {
      final r = await _flood(
        method: 'upload',
        streams: 8,
        peerHonoursWindow: true,
      );
      expect(r.errors, 0, reason: '$r');
      expect(r.after, '200', reason: '$r');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
