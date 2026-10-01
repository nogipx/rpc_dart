// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream responder is fed by the pipeline, not through
// `getMessagesForStream`, so the transport's per-stream buffer bound never sees
// it. Against a peer that ignores flow control, everything the peer sent was
// held for a handler that had stopped reading.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
final _chunk = ('z' * 1024).rpc;

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
      methodName: 'stalls',
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
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slowUnary',
      handler: (req, {RpcContext? context}) async {
        if (!s.entered.isCompleted) s.entered.complete();
        await s.hold.future;
        return 'len:${req.value.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'counts',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {
          s.consumed++;
        }
        return '${s.consumed}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// The peer: an rpc_dart caller with its windows off, which is what a peer
/// that ignores grants amounts to. The responder has its own policy.
({
  RpcCallerEndpoint caller,
  RpcChannelTransport client,
  Future<void> Function() close,
})
_rig(_State s, RpcSecurityPolicy serverPolicy) {
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
    policy: serverPolicy,
  );
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract(s))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  return (
    caller: caller,
    client: client,
    close: () async {
      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    },
  );
}

Stream<RpcString> _gen(_State s, int n) async* {
  for (var i = 0; i < n; i++) {
    if (s.stopProducing) return;
    s.produced++;
    yield _chunk;
    if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
  }
}

/// Floods a stalled handler, then releases it and counts what it drains: that
/// count is what the responder side held for it.
Future<({int retained, Object? error})> _flood(
  RpcSecurityPolicy serverPolicy,
) async {
  final s = _State();
  final r = _rig(s, serverPolicy);
  Object? error;
  final call = r.caller
      .clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'stalls',
        requestCodec: _codec,
        responseCodec: _codec,
      )(_gen(s, 2000))
      .then<void>((_) {}, onError: (Object e) => error = e);

  // The flood is over when the producer stops being pulled.
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
  await call.timeout(const Duration(seconds: 10), onTimeout: () {});
  await r.close();
  return (retained: retained, error: error);
}

void main() {
  test('a stalled client-stream handler holds no more than the message '
      'bound', () async {
    final r = await _flood(
      const RpcSecurityPolicy(maxBufferedMessagesPerStream: 64),
    );
    expect(r.retained, lessThanOrEqualTo(64), reason: 'retained $r');
    expect(
      r.error,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.resourceExhausted,
      ),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('nor more than the byte bound', () async {
    // 64 KiB against ~1 KiB messages: the byte ceiling binds first.
    final r = await _flood(
      const RpcSecurityPolicy(maxBufferedBytes: 64 * 1024),
    );
    expect(r.retained, lessThanOrEqualTo(64), reason: 'retained $r');
    expect(
      r.error,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.resourceExhausted,
      ),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('frames after a unary request are bounded while its handler '
      'runs', () async {
    // A unary state is never bound to a message stream, so these land in the
    // pre-bind buffer. Driven at the transport: no caller sends them.
    final s = _State();
    final r = _rig(
      s,
      const RpcSecurityPolicy(maxBufferedMessagesPerStream: 64),
    );
    final id = r.client.createStream();
    String? status;
    final sub = r.client.getMessagesForStream(id).listen((m) {
      status ??= m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
    }, onError: (Object _) {});
    await r.client.sendMetadata(
      id,
      RpcMetadata.forClientRequest('Svc', 'slowUnary'),
    );
    final junk = RpcMessageFrame.encode(_codec.serialize(_chunk));
    for (var i = 0; i < 2000 && status == null; i++) {
      await r.client.sendMessage(id, junk);
      if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (status == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      status,
      '${RpcStatus.resourceExhausted}',
      reason: 'the peer was never refused while the handler held its frames',
    );
    s.hold.complete();
    await sub.cancel();
    await r.close();
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('the unary pre-bind charge, at its boundary', () {
    // The request is charged, then taken by the dispatch. Frames after it must
    // get the whole limit: a charge left behind refuses one frame early.
    Future<String?> extraFrames(int n) async {
      final s = _State();
      final r = _rig(
        s,
        const RpcSecurityPolicy(maxBufferedMessagesPerStream: 16),
      );
      final id = r.client.createStream();
      String? status;
      final sub = r.client.getMessagesForStream(id).listen((m) {
        status ??= m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      }, onError: (Object _) {});
      await r.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'slowUnary'),
      );
      final frame = RpcMessageFrame.encode(_codec.serialize(_chunk));
      await r.client.sendMessage(id, frame);
      await s.entered.future.timeout(const Duration(seconds: 5));
      for (var i = 0; i < n; i++) {
        await r.client.sendMessage(id, frame);
      }
      // Lets the last frame reach the pipeline before the handler returns.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      s.hold.complete();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (status == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await sub.cancel();
      await r.close();
      return status;
    }

    test('exactly the limit fits', () async {
      expect(await extraFrames(16), '${RpcStatus.ok}');
    });

    test('one more is refused', () async {
      expect(await extraFrames(17), '${RpcStatus.resourceExhausted}');
    });
  });

  test(
    'a unary request split finer than the limit is still answered',
    () async {
      // A waiting unary is fed its fragments directly; charging them to the
      // pre-bind buffer as well would refuse this request at the 17th piece.
      final s = _State();
      final r = _rig(
        s,
        const RpcSecurityPolicy(maxBufferedMessagesPerStream: 16),
      );
      s.hold.complete();
      final id = r.client.createStream();
      String? status;
      final sub = r.client.getMessagesForStream(id).listen((m) {
        status ??= m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      }, onError: (Object _) {});
      await r.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'slowUnary'),
      );
      final frame = RpcMessageFrame.encode(_codec.serialize(_chunk));
      const piece = 16;
      for (var at = 0; at < frame.length; at += piece) {
        final end = at + piece < frame.length ? at + piece : frame.length;
        await r.client.sendMessage(id, frame.sublist(at, end));
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (status == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        status,
        '${RpcStatus.ok}',
        reason: '${(frame.length / piece).ceil()} fragments',
      );
      await sub.cancel();
      await r.close();
    },
  );

  test('CONTROL: a handler that keeps reading takes far more than the '
      'bound', () async {
    final s = _State();
    final r = _rig(
      s,
      const RpcSecurityPolicy(maxBufferedMessagesPerStream: 64),
    );
    final answer = await r.caller
        .clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'counts',
          requestCodec: _codec,
          responseCodec: _codec,
        )(_gen(s, 2000))
        .timeout(const Duration(seconds: 30));
    expect(answer.value, '2000');
    await r.close();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
