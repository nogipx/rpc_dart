// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A graceful drain decided whether to wait by reading a MAP KEY.
//
// Both connection-per-endpoint servers wrote the same count out:
//
//     final metrics = endpoint.collectEndpointMetrics();
//     total += (metrics['activeResponders'] as int?) ?? 0;
//
// `activeResponders` is an OBSERVABILITY key, sitting among a dozen others that
// exist to be read by a dashboard. Rename it -- or change its type, or move it
// under a sub-map -- and both servers count ZERO, every drain completes
// instantly, and the shutdown reports success while cutting live calls off.
// The failure looks exactly like the success.
//
// `drainUntilIdle` was already shared; the number feeding it was not, which is
// the half that decides whether a shutdown waits at all. It is now
// `RpcEndpointBase.activeResponderCount` -- typed, so the compiler is what
// checks it -- and the metrics key reads FROM it rather than beside it.
//
// Rounds 418 and 421 made this heavier: RpcApp now delegates shutdown to the
// server's drain, and stop() keeps serving until the drain finishes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Req implements IRpcSerializable {
  final String value;
  _Req(this.value);
  factory _Req.fromJson(Map<String, dynamic> json) =>
      _Req(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

class _Resp implements IRpcSerializable {
  final String value;
  _Resp(this.value);
  factory _Resp.fromJson(Map<String, dynamic> json) =>
      _Resp(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

/// A handler that parks until the test lets it go.
final class _ParkingService extends RpcResponderContract {
  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();

  _ParkingService() : super('Parking');

  @override
  void setup() {
    addUnaryMethod<_Req, _Resp>(
      methodName: 'Park',
      handler: (request, {context}) async {
        if (!started.isCompleted) started.complete();
        await finish.future;
        return _Resp('done');
      },
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
    );
  }
}

void main() {
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;
  late _ParkingService service;

  setUp(() {
    final pair = RpcInMemoryTransport.pair();
    caller = RpcCallerEndpoint(transport: pair.$1);
    responder = RpcResponderEndpoint(transport: pair.$2);
    service = _ParkingService();
    responder.registerServiceContract(service);
    responder.start();
  });

  tearDown(() async {
    if (!service.finish.isCompleted) service.finish.complete();
    await caller.close();
    await responder.close();
  });

  Future<void> startParkedCall() async {
    unawaited(
      caller
          .unaryRequest<_Req, _Resp>(
            serviceName: 'Parking',
            methodName: 'Park',
            request: _Req('x'),
            requestCodec: RpcCodec<_Req>(_Req.fromJson),
            responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
          )
          .catchError((Object _) => _Resp('gave up')),
    );
    await service.started.future.timeout(const Duration(seconds: 5));
  }

  test('a parked call is counted by the TYPED number a drain reads', () async {
    expect(responder.activeResponderCount, 0);

    await startParkedCall();

    expect(
      responder.activeResponderCount,
      greaterThan(0),
      reason: 'the drain polls this; if it reads 0 the shutdown never waits',
    );
  });

  // THE defect: the drain used to read the metrics MAP, so a rename there --
  // an observability change, free to make -- silently zeroed the count.
  test('the metrics key reads FROM the typed count, not beside it', () async {
    await startParkedCall();

    expect(
      responder.collectEndpointMetrics()['activeResponders'],
      responder.activeResponderCount,
      reason:
          'two independent computations of one number is how the map key and '
          'the shutdown decision came apart',
    );
  });

  // The shared count the servers now use, over a list of endpoints.
  test(
    'inFlightResponderCalls sums what the servers used to sum by hand',
    () async {
      expect(inFlightResponderCalls([responder]), 0);

      await startParkedCall();

      expect(
        inFlightResponderCalls([responder]),
        responder.activeResponderCount,
      );
    },
  );

  // GUARD: an endpoint with no responder half counts zero rather than throwing.
  // That is the honest default -- it is serving nothing -- and a server may
  // hold both kinds.
  test('GUARD: a caller-only endpoint counts zero', () {
    expect(caller.activeResponderCount, 0);
    expect(inFlightResponderCalls([caller]), 0);
  });

  // GUARD: the count comes back down, or a drain would never converge.
  test('GUARD: the count returns to zero when the call finishes', () async {
    await startParkedCall();
    expect(responder.activeResponderCount, greaterThan(0));

    service.finish.complete();
    for (var i = 0; i < 100 && responder.activeResponderCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(responder.activeResponderCount, 0);
  });
}
