// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The natural shape of a bidirectional call is a SUBSCRIPTION: the client opens
// the channel, listens, and may send nothing for a long time. That call did not
// reach the server at all.
//
// Two hops had to be fixed, and instrumenting both at once is what separated
// them (L-07). Measured with a handler that pushes five messages:
//
//   before          openStreams=0  responders=0  caller hung
//   after hop 1     openStreams=1  responders=0  caller hung
//   after hop 2     5 delivered, stream closed
//
//   hop 1  initial metadata is sent by the first request or by the half-close,
//          and a subscription does neither, so the call was never announced.
//   hop 2  the responder is dispatched by a request frame or by the half-close,
//          and a subscription sends neither, so the handler never ran.
//
// `bidi_empty_request_stream_test.dart` covers the neighbouring case — zero
// messages AND a half-close — which already worked and still does. The
// difference is whether the request stream CLOSES.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'pushOnly',
      handler: (reqs, {RpcContext? context}) async* {
        for (var i = 0; i < 5; i++) {
          yield 'p$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'endsFirst',
      handler: (reqs, {RpcContext? context}) async* {
        yield 'only'.rpc;
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
  await r.caller.close().catchError((_) {});
  await r.responder.close().catchError((_) {});
  await r.client.close().catchError((_) {});
  await r.server.close().catchError((_) {});
}

/// A request stream that never produces and never closes.
Stream<RpcString> _never() => StreamController<RpcString>().stream;

Future<List<String>> _collect(_Rig rig, String method) async {
  final got = <String>[];
  await for (final r in rig.caller.bidirectionalStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: method,
    requests: _never(),
    requestCodec: _codec,
    responseCodec: _codec,
  )) {
    got.add(r.value);
  }
  return got;
}

void main() {
  test('WITNESS: a caller that never sends still receives', () async {
    final rig = _connect();

    final got = await _collect(rig, 'pushOnly').timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the call never reached the server: a bidirectional caller that holds '
        'its request stream open sends neither a request frame nor a '
        'half-close, and both the initial metadata and the responder dispatch '
        'were waiting for one of those',
      ),
    );

    expect(got, ['p0', 'p1', 'p2', 'p3', 'p4']);
    await _teardown(rig);
  });

  test('WITNESS: the server may end the call first', () async {
    final rig = _connect();

    final got = await _collect(rig, 'endsFirst').timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          fail('the caller never saw the end of a call the server finished'),
    );

    expect(got, ['only']);
    await _teardown(rig);
  });

  test('WITNESS: the server hears the call before any request', () async {
    // The hop-1 half on its own: the responder knows the stream exists while
    // the caller is still silent. Asserted as an EVENT at the peer rather than
    // by polling a gauge that also falls again (L-11) — the handler below never
    // completes, so the state cannot be reclaimed underneath the check.
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    final started = Completer<void>();

    final contract = _HangingContract(started);
    responder.registerServiceContract(contract);
    responder.start();

    final sub = caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'hangs',
          requests: _never(),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});

    await started.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the handler never started for a caller that had not sent anything',
      ),
    );

    await sub.cancel();
    await caller.close().catchError((_) {});
    await responder.close().catchError((_) {});
    await client.close();
    await server.close();
  });

  test('GUARD: zero messages WITH a half-close still works', () async {
    // The neighbouring case, which worked before these fixes. It must keep
    // working, and it must not be what the witnesses above are measuring.
    final rig = _connect();

    final got = <String>[];
    await for (final r in rig.caller.bidirectionalStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'pushOnly',
      requests: const Stream<RpcString>.empty(),
      requestCodec: _codec,
      responseCodec: _codec,
    )) {
      got.add(r.value);
    }

    expect(got, ['p0', 'p1', 'p2', 'p3', 'p4']);
    await _teardown(rig);
  });
}

final class _HangingContract extends RpcResponderContract {
  _HangingContract(this._started) : super('Svc');

  final Completer<void> _started;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'hangs',
      handler: (reqs, {RpcContext? context}) async* {
        if (!_started.isCompleted) _started.complete();
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
