// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Flow control bounded the server->client direction but not client->server: an
// upload ran as far ahead of a stalled handler as the application could feed
// it. Measured with a bidirectional handler that consumed one message and then
// stalled, against a 1 MB window, with the requests supplied by a generator so
// the count is what the LIBRARY pulled rather than what the app queued:
//
//   before: caller pulled 2000 messages (~32.8 MB), handler consumed 1
//   after:  caller pulled   66 messages (~1.1 MB),  handler consumed 1
//
// Two things were needed, and an ablation shows both are load-bearing --
// removing either one restores the full 2000:
//
//   * The responder-side demand chain (StreamProcessor's request controller,
//     and the pipeline's bound stream) so a stalled handler stops the metered
//     per-stream stream being drained, which is what withholds credit.
//   * Backpressure in the caller's request pump. It enqueued each send onto a
//     future sequence and returned, so the request stream was drained at full
//     speed however long a send took -- an unbounded queue between the
//     application and the transport.
//
// The client-stream upload direction is still unbounded and asserted as such
// below: that responder is fed by the pipeline rather than through
// getMessagesForStream, so its frames are credited on arrival and there is
// nothing to meter.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

int _consumed = 0;
Completer<void> _hold = Completer<void>();

final _chunk = ('z' * 16384).rpc;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'stalls',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final _ in reqs) {
          _consumed++;
          await _hold.future;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'stallsUpload',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {
          _consumed++;
          await _hold.future;
        }
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'mirror',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'ignores',
      handler: (reqs, {RpcContext? context}) async* {
        // Never reads its request stream. Nothing pauses, so the peer must
        // stay unthrottled rather than park forever.
        for (var i = 0; i < 5; i++) {
          yield 'p$i'.rpc;
        }
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
        return 'c:$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect({int? window = 1024 * 1024}) {
  final policy = RpcSecurityPolicy(flowControlWindowBytes: window);
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<void> _teardown(_Rig r) async {
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

/// Requests supplied by a generator, so [pulled] counts what the library took
/// rather than what a StreamController accepted.
Stream<RpcString> _gen(int n, void Function() onPull) async* {
  for (var i = 0; i < n; i++) {
    onPull();
    yield _chunk;
    if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    _consumed = 0;
    _hold = Completer<void>();
  });
  tearDown(() {
    if (!_hold.isCompleted) _hold.complete();
  });

  group('an upload is bounded by the window', () {
    test('bidirectional, against a stalled handler', () async {
      final rig = _connect(window: 1024 * 1024);
      var pulled = 0;
      unawaited(
        rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'stalls',
              requests: _gen(2000, () => pulled++),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .drain<void>()
            .catchError((Object _) {}),
      );

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        _consumed,
        lessThan(5),
        reason: 'the handler is supposed to be stalled',
      );
      // 1 MB / 16 KiB = 64 messages, plus what was already in flight.
      expect(
        pulled,
        lessThan(400),
        reason:
            'the caller pulled $pulled messages (~'
            '${(pulled * 16384 / 1e6).toStringAsFixed(1)} MB) from its request '
            'stream while the handler had consumed $_consumed',
      );

      _hold.complete();
      await _teardown(rig);
    });

    test('disabling the window restores the unbounded behaviour', () async {
      final rig = _connect(window: null);
      var pulled = 0;
      unawaited(
        rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'stalls',
              requests: _gen(2000, () => pulled++),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .drain<void>()
            .catchError((Object _) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        pulled,
        greaterThan(1000),
        reason: 'with no window the caller should be unthrottled',
      );
      _hold.complete();
      await _teardown(rig);
    });

    test('client-stream upload is NOT yet bounded', () async {
      // Documented gap, asserted so a future fix has to update this. That
      // responder is fed by the pipeline rather than through
      // getMessagesForStream, so its frames are credited on arrival.
      final rig = _connect(window: 1024 * 1024);
      var pulled = 0;
      unawaited(
        rig.caller
            .clientStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'stallsUpload',
              requestCodec: _codec,
              responseCodec: _codec,
            )(_gen(2000, () => pulled++))
            .catchError((Object _) => ''.rpc),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(pulled, greaterThan(500));
      _hold.complete();
      await _teardown(rig);
    });
  });

  group('nothing deadlocks on its own window', () {
    test('a handler that never reads its requests', () async {
      // Nothing pauses, so no credit is withheld and the peer keeps sending.
      final rig = _connect(window: 64 * 1024);
      var pulled = 0;
      final got = await rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'ignores',
            requests: _gen(300, () => pulled++),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                fail('a handler that ignores requests stalled its peer'),
          );
      expect(got, hasLength(5));
      await _teardown(rig);
    });

    test('a mirroring handler far exceeding the window', () async {
      final rig = _connect(window: 64 * 1024);
      var pulled = 0;
      final got = await rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'mirror',
            requests: _gen(300, () => pulled++),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(const Duration(seconds: 20));
      expect(got, hasLength(300), reason: '4.9 MB through a 64 KiB window');
      expect(pulled, 300);
      await _teardown(rig);
    });

    test('a client-stream upload still completes', () async {
      final rig = _connect(window: 64 * 1024);
      var pulled = 0;
      expect(
        (await rig.caller
                .clientStream<RpcString, RpcString>(
                  serviceName: 'Svc',
                  methodName: 'counts',
                  requestCodec: _codec,
                  responseCodec: _codec,
                )(_gen(300, () => pulled++))
                .timeout(const Duration(seconds: 20)))
            .value,
        'c:300',
      );
      await _teardown(rig);
    });

    test('tearing down mid-upload does not hang', () async {
      final rig = _connect(window: 64 * 1024);
      var pulled = 0;
      unawaited(
        rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'stalls',
              requests: _gen(2000, () => pulled++),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .drain<void>()
            .catchError((Object _) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _teardown(rig).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('teardown hung with a parked request pump'),
      );
      _hold.complete();
    });

    test('ordering is preserved under backpressure', () async {
      final rig = _connect(window: 64 * 1024);
      Stream<RpcString> ordered() async* {
        for (var i = 0; i < 200; i++) {
          yield 'm$i'.rpc;
        }
      }

      final got = await rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'mirror',
            requests: ordered(),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((r) => r.value)
          .toList()
          .timeout(const Duration(seconds: 20));
      expect(got, [for (var i = 0; i < 200; i++) 'm$i']);
      await _teardown(rig);
    });
  });
}
