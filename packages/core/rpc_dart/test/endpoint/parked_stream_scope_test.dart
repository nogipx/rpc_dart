// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// What halfOpenStreamTimeout actually buys, measured rather than assumed.
//
// It reclaims a stream that never dispatches. It does NOT reclaim one that
// dispatches and then goes idle, and a peer gets that for about 30 extra bytes
// -- one request frame on a client-streaming method leaves the handler waiting
// forever on a request stream that never half-closes:
//
//   metadata only             : openStreams=0 after 1.5s, next call OK
//   metadata + 1 request frame: openStreams=8 forever, next call RESOURCE_EXHAUSTED
//
// Bounding that needs an idle-stream timeout, which cannot be safe by default:
// a stream idle in both directions is also exactly what a legitimate
// rare-event subscription looks like. So the limitation is asserted here rather
// than papered over, and a future idle timeout has to update this file.
//
// The blast radius is narrower than the earlier commentary on this fix claimed.
// A responder endpoint is created per connection, so the stream table and
// maxActiveStreams are per connection: wedging one does not touch another.
// The cost that does cross connections is memory -- measured at 68.2 MB for
// 2000 parked streams, about 33 KiB each, so roughly maxActiveStreams x 33 KiB
// per connection a peer opens.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {}
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'p'.rpc,
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

/// Built by hand so the client can carry a larger ceiling than the server:
/// a test that holds client-side stream ids would otherwise trip the CLIENT's
/// own limit and report a StateError from createStream, which says nothing
/// about the server being wedged.
_Rig _connect({int limit = 8, int clientLimit = 256}) {
  final serverPolicy = RpcSecurityPolicy(
    maxActiveStreams: limit,
    halfOpenStreamTimeout: const Duration(milliseconds: 300),
  );
  final clientPolicy = RpcSecurityPolicy(
    maxActiveStreams: clientLimit,
    halfOpenStreamTimeout: const Duration(milliseconds: 300),
  );
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(
    policy: clientPolicy,
  );
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: clientPolicy,
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: serverPolicy,
  );
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

int _open(_Rig rig) =>
    rig.responder.collectEndpointMetrics()['openStreams']! as int;

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Opens [n] streams, optionally sending one request frame so the handler is
/// dispatched, and never half-closes.
Future<void> _park(_Rig rig, int n, {required bool dispatch}) async {
  for (var i = 0; i < n; i++) {
    final sid = rig.client.createStream();
    await rig.client.sendMetadata(
      sid,
      RpcMetadata([
        RpcHeader(RpcHeaders.contentType, 'application/grpc+proto'),
      ], methodPath: '/Svc/upload'),
    );
    if (dispatch) {
      await rig.client.sendMessage(
        sid,
        RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
      );
    }
    // Release client-side so the CLIENT ceiling is never what we measure.
    rig.client.releaseStreamId(sid);
  }
}

Future<Object?> _callPing(_Rig rig) async {
  try {
    await rig.caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'ping',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  group('what the half-open timeout covers', () {
    test('an undispatched stream is reclaimed', () async {
      final rig = _connect();
      await _park(rig, 8, dispatch: false);
      await _waitUntil(() => _open(rig) == 8);
      await _waitUntil(() => _open(rig) == 0);
      expect(_open(rig), 0);
      expect(await _callPing(rig), isNull, reason: 'the slots came back');
      await _teardown(rig);
    });

    test('one request frame parks the stream anyway', () async {
      // The documented limitation. If this ever starts failing, an idle-stream
      // timeout has been added and the commentary above needs updating.
      final rig = _connect();
      await _park(rig, 8, dispatch: true);
      await _waitUntil(() => _open(rig) == 8);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(
        _open(rig),
        8,
        reason: 'dispatched-but-idle streams are not covered by this timeout',
      );
      expect(
        await _callPing(rig),
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
      );
      await _teardown(rig);
    });
  });

  group('the blast radius is one connection', () {
    test('a wedged connection does not affect another', () async {
      // A responder endpoint is per connection, so its stream table is too.
      final wedged = _connect();
      final healthy = _connect();

      await _park(wedged, 8, dispatch: true);
      await _waitUntil(() => _open(wedged) == 8);

      expect(
        await _callPing(wedged),
        isA<RpcStatusException>(),
        reason: 'the wedged connection should refuse its own calls',
      );
      expect(
        await _callPing(healthy),
        isNull,
        reason: 'a separate connection must be unaffected',
      );
      expect(_open(healthy), 0);

      await _teardown(wedged);
      await _teardown(healthy);
    });

    test('a wedged connection recovers once its streams end', () async {
      // The half-closes the peer withheld; the slots come straight back.
      final rig = _connect();
      final ids = <int>[];
      for (var i = 0; i < 8; i++) {
        final sid = rig.client.createStream();
        ids.add(sid);
        await rig.client.sendMetadata(
          sid,
          RpcMetadata([
            RpcHeader(RpcHeaders.contentType, 'application/grpc+proto'),
          ], methodPath: '/Svc/upload'),
        );
        await rig.client.sendMessage(
          sid,
          RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
        );
      }
      await _waitUntil(() => _open(rig) == 8);
      expect(await _callPing(rig), isA<RpcStatusException>());

      for (final sid in ids) {
        await rig.client.finishSending(sid);
      }
      await _waitUntil(() => _open(rig) == 0);
      expect(_open(rig), 0);
      expect(await _callPing(rig), isNull);
      await _teardown(rig);
    });
  });
}
