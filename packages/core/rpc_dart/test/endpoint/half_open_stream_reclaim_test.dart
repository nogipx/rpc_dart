// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer-opened stream is half-open from its metadata frame until a handler is
// dispatched, which needs a request message (or, for the streaming-request
// shapes, a half-close). Nothing bounded that window: `grpc-timeout` is the
// only other thing that limits a stream's life and it is optional and
// peer-supplied, so an attacker simply omits it.
//
// That made maxActiveStreams the exact size of a permanent wedge. Measured
// against a server configured with maxActiveStreams: 8, sending eight
// metadata-only frames and nothing else:
//
//   after opening 8 half-open streams: openStreams=8
//   after 3 more seconds:              openStreams=8      <-- never reclaimed
//   legitimate call: RpcStatusException(8): Too many concurrent streams
//
// Unauthenticated, permanent, and 4096 tiny frames at the default ceiling. With
// halfOpenStreamTimeout the slots come back and the server keeps serving.
//
// The window covers dispatch only, so a running handler is never touched by it
// however long it lives -- that is what separates this from a request deadline.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Completer<void> _hold = Completer<void>();
List<String> _got = [];

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async => 'u:${r.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slowUnary',
      handler: (r, {RpcContext? context}) async {
        await _hold.future;
        return 'slow'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      handler: (reqs, {RpcContext? context}) async {
        await for (final r in reqs) {
          _got.add(r.value);
        }
        return 'ok:${_got.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'push',
      handler: (reqs, {RpcContext? context}) async* {
        yield 'first'.rpc;
        await _hold.future;
        yield 'last'.rpc;
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

_Rig _connect({
  int maxActiveStreams = 8,
  Duration? halfOpen = const Duration(milliseconds: 300),
}) {
  final policy = RpcSecurityPolicy(
    maxActiveStreams: maxActiveStreams,
    halfOpenStreamTimeout: halfOpen,
  );
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

/// Opens [n] streams that send only their metadata frame, like a hostile peer.
Future<List<int>> _openHalfOpen(_Rig rig, int n) async {
  final ids = <int>[];
  for (var i = 0; i < n; i++) {
    final sid = rig.client.createStream();
    ids.add(sid);
    await rig.client.sendMetadata(
      sid,
      RpcMetadata([
        RpcHeader(RpcHeaders.contentType, 'application/grpc+proto'),
      ], methodPath: '/Svc/unary'),
    );
  }
  return ids;
}

int _open(_Rig rig) =>
    rig.responder.collectEndpointMetrics()['openStreams']! as int;

void main() {
  setUp(() {
    _hold = Completer<void>();
    _got = [];
  });
  tearDown(() {
    if (!_hold.isCompleted) _hold.complete();
  });

  group('a half-open stream cannot park a slot forever', () {
    test('the slots come back and the server keeps serving', () async {
      final rig = _connect();
      final ids = await _openHalfOpen(rig, 8);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_open(rig), 8, reason: 'all eight should be parked at first');

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        _open(rig),
        0,
        reason: 'half-open streams should have been reclaimed',
      );

      // Release the ids client-side so the CLIENT ceiling is not what we then
      // measure -- the point is that the SERVER is serving again.
      for (final id in ids) {
        rig.client.releaseStreamId(id);
      }
      final r = await rig.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'unary',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
      expect(r.value, 'u:x');
      await _teardown(rig);
    });

    test('repeated waves do not accumulate', () async {
      final rig = _connect();
      for (var wave = 0; wave < 3; wave++) {
        final ids = await _openHalfOpen(rig, 4);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(_open(rig), 0, reason: 'wave $wave should be fully reclaimed');
        for (final id in ids) {
          rig.client.releaseStreamId(id);
        }
      }
      await _teardown(rig);
    });

    test('setting the timeout to null keeps the old behaviour', () async {
      // Opt-out has to actually opt out.
      final rig = _connect(halfOpen: null);
      await _openHalfOpen(rig, 4);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(_open(rig), 4);
      await _teardown(rig);
    });
  });

  group('a dispatched handler is never reclaimed', () {
    test('a unary handler outliving the window still answers', () async {
      // The window covers dispatch, not execution.
      final rig = _connect();
      final call = rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'slowUnary',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(_open(rig), 1, reason: 'the running handler must still be open');
      _hold.complete();
      expect((await call.timeout(const Duration(seconds: 5))).value, 'slow');
      await _teardown(rig);
    });

    test('a client stream with long gaps between messages', () async {
      // Dispatch happens on the first message, so the gaps that follow are
      // outside the window entirely.
      final rig = _connect();
      final requests = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'upload',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);

      for (var i = 0; i < 3; i++) {
        requests.add('c$i'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await requests.close();

      expect((await call.timeout(const Duration(seconds: 5))).value, 'ok:3');
      expect(_got, ['c0', 'c1', 'c2']);
      await _teardown(rig);
    });

    test('a bidirectional stream idle well past the window', () async {
      final rig = _connect();
      final requests = StreamController<RpcString>()..add('a'.rpc);
      final got = <String>[];
      final done = rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'push',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .forEach((r) => got.add(r.value));

      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(got, ['first'], reason: 'the handler should still be alive');
      _hold.complete();
      await requests.close();
      await done.timeout(const Duration(seconds: 5));
      expect(got, ['first', 'last']);
      await _teardown(rig);
    });

    test('ordinary calls are unaffected under repetition', () async {
      final rig = _connect();
      for (var i = 0; i < 25; i++) {
        final r = await rig.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'unary',
          request: 'n$i'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
        expect(r.value, 'u:n$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(_open(rig), 0);
      await _teardown(rig);
    });
  });

  group('policy plumbing', () {
    test('the default is a finite window', () {
      expect(const RpcSecurityPolicy().halfOpenStreamTimeout, isNotNull);
    });

    test('survives a map round-trip', () {
      const policy = RpcSecurityPolicy(
        halfOpenStreamTimeout: Duration(seconds: 5),
      );
      expect(
        RpcSecurityPolicy.fromMap(policy.toMap()).halfOpenStreamTimeout,
        const Duration(seconds: 5),
      );
    });

    test('a disabled window round-trips as disabled', () {
      const policy = RpcSecurityPolicy(halfOpenStreamTimeout: null);
      expect(
        RpcSecurityPolicy.fromMap(policy.toMap()).halfOpenStreamTimeout,
        isNull,
      );
    });

    test('an absent key keeps the default', () {
      expect(
        RpcSecurityPolicy.fromMap(const {}).halfOpenStreamTimeout,
        const RpcSecurityPolicy().halfOpenStreamTimeout,
      );
    });
  });
}
