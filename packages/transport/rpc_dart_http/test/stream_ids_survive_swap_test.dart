// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttpCallerTransport has no reconnect() of its own, so the only thing that
// swaps it is RpcClientConnection — which builds a NEW transport per attempt.
// A new one restarts its stream ids at 1, so the first call after the swap is
// handed the id a call from the previous transport still holds, and every
// caller releases its id and finishes sending BY ID.
//
// The collision bites harder here than on the streaming transports, because
// HTTP/1.1 buffers the whole request and `finishSending` is what SENDS it:
//
//   _pending[id]        holds the buffered body
//   finishSending(id)   -> _fireRequest(id) -> takes _pending[id] and POSTs it
//   releaseStreamId(id) -> _pending.remove(id), discarding it
//
// Measured through RpcClientConnection with one forceReconnect between two
// calls:
//
//   before : A and B both get id 1; A's late finishSending(1) POSTed B's
//            request and the handler saw `call-B` while B's caller was still
//            buffering its body
//   after  : A keeps 1, B gets 3, and nothing is sent until B says so
//
// Fixed by implementing IRpcStreamIdSequence, so the watermark
// RpcClientConnection already carries reaches this transport too.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._seen) : super('Svc');

  final List<String> _seen;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async {
        _seen.add(r.value);
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Fixture = ({
  RpcClientConnection connection,
  List<String> seen,
  int Function() built,
});

Future<_Fixture> _build() async {
  final seen = <String>[];
  var built = 0;

  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) {
      e.registerServiceContract(_Svc(seen));
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();
  final baseUrl = 'http://127.0.0.1:${server.actualPort}';

  final connection = RpcClientConnection(
    transportFactory: () async {
      built++;
      return RpcHttpCallerTransport(baseUrl: baseUrl);
    },
  );
  addTearDown(() async {
    await connection.dispose();
    await server.stop();
  });
  return (connection: connection, seen: seen, built: () => built);
}

Future<void> _online(_Fixture f) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (f.connection.currentState is RpcClientOnline) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('the connection never came online');
}

/// Forces a swap and waits for the REPLACEMENT to exist.
///
/// The build count, not the state: forceReconnect() detaches asynchronously, so
/// the state is still Online when it returns and a state-only wait falls
/// straight through.
Future<void> _swap(_Fixture f) async {
  final before = f.built();
  f.connection.forceReconnect();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (f.built() > before && f.connection.currentState is RpcClientOnline) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('the connection never rebuilt its transport');
}

/// Opens a call and BUFFERS its body without firing it, which is exactly where
/// a caller sits between `sendMetadata` and its final send.
Future<int> _openBuffered(IRpcTransport t, String body) async {
  final id = t.createStream();
  t.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await t.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'echo'));
  await t.sendMessage(id, RpcMessageFrame.encode(_codec.serialize(body.rpc)));
  return id;
}

void main() {
  test('WITNESS: a call after a swap does not reuse a live id', () async {
    final f = await _build();
    f.connection.connect();
    await _online(f);

    final idA = await _openBuffered(f.connection.transport, 'call-A');
    await _swap(f);
    final idB = await _openBuffered(f.connection.transport, 'call-B');

    expect(
      idB,
      isNot(idA),
      reason:
          'the replacement transport restarted its id sequence, so B was '
          'handed the id A still holds',
    );
  });

  test("WITNESS: a dead call's teardown does not fire a live request", () async {
    final f = await _build();
    f.connection.connect();
    await _online(f);

    final idA = await _openBuffered(f.connection.transport, 'call-A');
    await _swap(f);
    await _openBuffered(f.connection.transport, 'call-B');
    expect(f.seen, isEmpty, reason: 'nothing has finished sending yet');

    // A's teardown, arriving after the swap. This is the line every caller runs
    // when it is done sending.
    await f.connection.transport.finishSending(idA);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      f.seen,
      isEmpty,
      reason:
          "a dead call fired the live call's request: the handler ran while "
          "B's caller was still buffering its body",
    );
  });

  group('GUARD: the ordinary paths still work', () {
    test('a call still completes after a swap', () async {
      // Load-bearing: "nothing was sent" would also hold for a transport that
      // stopped working entirely after the swap.
      final f = await _build();
      f.connection.connect();
      await _online(f);

      final caller = RpcCallerEndpoint(transport: f.connection.transport);
      expect(
        (await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'first'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value,
        'first',
      );

      await _swap(f);

      expect(
        (await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'second'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value,
        'second',
      );
      expect(f.seen, ['first', 'second']);
    });

    test('finishSending on the CURRENT transport still fires', () async {
      // The watermark must not turn ordinary ids into no-ops.
      final f = await _build();
      f.connection.connect();
      await _online(f);

      final id = await _openBuffered(f.connection.transport, 'live');
      await f.connection.transport.finishSending(id);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(f.seen, ['live']);
    });
  });
}
