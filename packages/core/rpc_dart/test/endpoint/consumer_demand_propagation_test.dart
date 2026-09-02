// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `pause()` on a stream returned by serverStream()/bidirectionalStream()
// stopped delivery to the listener and nothing else. The controller handed to
// the caller drained the entire response chain at full speed regardless, so
// every stage kept decoding and materialising responses nobody had asked for.
//
// Measured by counting events at every hop with a paused consumer, over 2s
// (the consumer held at 1400 messages):
//
//   transport route  +4600   processor recv  +4600   processor emit  +4601
//   transformer      +4600   caller yield    +4600   pipeline add    +4600
//
// Two hops were missing: the caller pipeline's user-facing controller, and
// CallProcessor's response controller. With both wired, the same measurement
// gives +0/+1 for every stage above the transport, and buffering collapses back
// to the transport's own per-stream controller -- where messages sit as
// undecoded frames instead of decoded objects spread across five stages.
//
// The transport keeps accepting what the peer sends (that is what per-stream
// flow control is for, and it needs this chain working first: a metered
// transport stream only stops being drained once the stages above it stop
// pulling).
//
// Decode count is the observable proxy here: deserialization happens in the
// processor, so it only advances while the chain is still pulling.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Counts every deserialization, which only happens while the chain pulls.
int _decodes = 0;

final class _Counted implements IRpcSerializable {
  const _Counted(this.value);
  final String value;

  factory _Counted.fromJson(Map<String, dynamic> json) {
    _decodes++;
    return _Counted(json['v'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'v': value};
}

final _codec = RpcCodec<_Counted>(_Counted.fromJson);

int _produced = 0;
Completer<void> _stop = Completer<void>();

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<_Counted, _Counted>(
      methodName: 'firehose',
      handler: (r, {RpcContext? context}) async* {
        while (!_stop.isCompleted) {
          _produced++;
          yield const _Counted('x');
          if (_produced % 50 == 0) await Future<void>.delayed(Duration.zero);
          if (_produced >= 4000) break;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<_Counted, _Counted>(
      methodName: 'few',
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 5; i++) {
          yield _Counted('s$i');
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<_Counted, _Counted>(
      methodName: 'fails',
      handler: (r, {RpcContext? context}) async* {
        yield const _Counted('a');
        throw RpcStatusException(RpcStatus.notFound, 'gone');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<_Counted, _Counted>(
      methodName: 'bidiFirehose',
      handler: (reqs, {RpcContext? context}) async* {
        while (!_stop.isCompleted) {
          _produced++;
          yield const _Counted('y');
          if (_produced % 50 == 0) await Future<void>.delayed(Duration.zero);
          if (_produced >= 4000) break;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<_Counted, _Counted>(
      methodName: 'mirror',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          yield r;
        }
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

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
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

Stream<_Counted> _one() {
  final c = StreamController<_Counted>();
  c.add(const _Counted('a'));
  unawaited(c.close());
  return c.stream;
}

void main() {
  setUp(() {
    _decodes = 0;
    _produced = 0;
    _stop = Completer<void>();
  });
  tearDown(() {
    if (!_stop.isCompleted) _stop.complete();
  });

  group('a paused consumer stops the response chain', () {
    test('server stream', () async {
      final rig = _connect();
      var got = 0;
      final sub = rig.caller
          .serverStream<_Counted, _Counted>(
            serviceName: 'Svc',
            methodName: 'firehose',
            request: const _Counted('go'),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) => got++, onError: (Object _) {});

      await Future<void>.delayed(const Duration(milliseconds: 150));
      sub.pause();
      final decodesAtPause = _decodes;
      expect(
        decodesAtPause,
        greaterThan(0),
        reason: 'the chain should have been running before the pause',
      );

      await Future<void>.delayed(const Duration(milliseconds: 800));
      // The server keeps producing -- only flow control stops that -- but this
      // side must stop decoding for a consumer that has stopped asking.
      expect(
        _decodes - decodesAtPause,
        lessThanOrEqualTo(2),
        reason:
            'decoding continued while paused: ${_decodes - decodesAtPause} '
            'extra messages were materialised for a consumer that had stopped '
            'reading (server produced $_produced)',
      );

      _stop.complete();
      sub.resume();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(got, greaterThan(0));
      await sub.cancel();
      await _teardown(rig);
    });

    test('bidirectional stream', () async {
      final rig = _connect();
      final requests = StreamController<_Counted>()..add(const _Counted('a'));
      final sub = rig.caller
          .bidirectionalStream<_Counted, _Counted>(
            serviceName: 'Svc',
            methodName: 'bidiFirehose',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) {}, onError: (Object _) {});

      await Future<void>.delayed(const Duration(milliseconds: 150));
      sub.pause();
      final decodesAtPause = _decodes;
      expect(decodesAtPause, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        _decodes - decodesAtPause,
        lessThanOrEqualTo(2),
        reason:
            'decoding continued while paused: ${_decodes - decodesAtPause} '
            'extra messages (server produced $_produced)',
      );

      _stop.complete();
      sub.resume();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      await requests.close();
      await _teardown(rig);
    });
  });

  group('every ordinary path is unaffected', () {
    test('a resumed consumer receives everything, in order', () async {
      final rig = _connect();
      final got = <String>[];
      final sub = rig.caller
          .serverStream<_Counted, _Counted>(
            serviceName: 'Svc',
            methodName: 'few',
            request: const _Counted('go'),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((r) => got.add(r.value));

      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      sub.resume();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(got, ['s0', 's1', 's2', 's3', 's4']);
      await sub.cancel();
      await _teardown(rig);
    });

    test('an uninterrupted stream still completes', () async {
      final rig = _connect();
      expect(
        await rig.caller
            .serverStream<_Counted, _Counted>(
              serviceName: 'Svc',
              methodName: 'few',
              request: const _Counted('go'),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .map((r) => r.value)
            .toList()
            .timeout(const Duration(seconds: 5)),
        ['s0', 's1', 's2', 's3', 's4'],
      );
      await _teardown(rig);
    });

    test('an error still propagates', () async {
      final rig = _connect();
      await expectLater(
        rig.caller
            .serverStream<_Counted, _Counted>(
              serviceName: 'Svc',
              methodName: 'fails',
              request: const _Counted('go'),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList()
            .timeout(const Duration(seconds: 5)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.notFound,
          ),
        ),
      );
      await _teardown(rig);
    });

    test('cancelling while paused does not hang', () async {
      // Pausing now holds a subscription open further up the chain, so the
      // teardown path has to work from that state too.
      final rig = _connect();
      final sub = rig.caller
          .serverStream<_Counted, _Counted>(
            serviceName: 'Svc',
            methodName: 'firehose',
            request: const _Counted('go'),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) {}, onError: (Object _) {});

      await Future<void>.delayed(const Duration(milliseconds: 150));
      sub.pause();
      await sub.cancel().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('cancel deadlocked on a paused subscription'),
      );
      _stop.complete();
      await _teardown(rig);
    });

    test('a bidi stream the client ends normally', () async {
      final rig = _connect();
      expect(
        await rig.caller
            .bidirectionalStream<_Counted, _Counted>(
              serviceName: 'Svc',
              methodName: 'mirror',
              requests: _one(),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .map((r) => r.value)
            .toList()
            .timeout(const Duration(seconds: 5)),
        ['a'],
      );
      await _teardown(rig);
    });

    test('repeated calls leave no state behind', () async {
      final rig = _connect();
      for (var i = 0; i < 20; i++) {
        await rig.caller
            .serverStream<_Counted, _Counted>(
              serviceName: 'Svc',
              methodName: 'few',
              request: const _Counted('go'),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList();
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rig.caller.collectEndpointMetrics()['pendingRequests'], 0);
      expect(rig.responder.collectEndpointMetrics()['openStreams'], 0);
      await _teardown(rig);
    });
  });
}
