// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `endpoint.close()` was the one teardown that did not tell the handler.
//
// Four paths in the responder pipeline cancel the context token before tearing
// a stream down -- `_abortActiveStreams` (both the transport-closed and the
// drain arms) and the two per-stream cleanups -- and each carries the same
// reasoning: a handler that polls `cancellationToken` or awaits `cancelled`
// unwinds cooperatively only if something cancels it.
//
// `closeResponderResources` went straight to `_cleanupStream`. So a handler
// still running when the endpoint closed was never told: it kept going against
// controllers that had already been torn down, and `close()` returned while it
// ran. `drain()` did the right thing and `close()` did not, which is the
// opposite of what a caller would guess from the two names.

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

/// A handler that parks until it is cancelled, and records which way it ended.
final class _ParkingService extends RpcResponderContract {
  final Completer<void> started = Completer<void>();
  final Completer<String> ended = Completer<String>();

  /// Escape hatch so a handler nobody cancels cannot hang the suite.
  final Completer<void> release = Completer<void>();

  _ParkingService() : super('Parking');

  @override
  void setup() {
    addUnaryMethod<_Req, _Resp>(
      methodName: 'Park',
      handler: (request, {context}) async {
        if (!started.isCompleted) started.complete();
        final token = context?.cancellationToken;
        await Future.any([release.future, if (token != null) token.cancelled]);
        final how = (token?.isCancelled ?? false)
            ? 'cancelled: ${token!.reason}'
            : 'released';
        if (!ended.isCompleted) ended.complete(how);
        return _Resp(how);
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
    if (!service.release.isCompleted) service.release.complete();
    await caller.close();
    await responder.close();
  });

  /// Starts a call and returns once its handler is running.
  Future<void> startInFlightCall() async {
    unawaited(
      caller
          .unaryRequest<_Req, _Resp>(
            serviceName: 'Parking',
            methodName: 'Park',
            request: _Req('x'),
            requestCodec: RpcCodec<_Req>(_Req.fromJson),
            responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
          )
          .catchError((Object _) => _Resp('caller gave up')),
    );
    await service.started.future.timeout(const Duration(seconds: 5));
  }

  test('close() cancels the token of a handler still running', () async {
    await startInFlightCall();

    await responder.close();

    final how = await service.ended.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the handler was never told: close() tore the stream down without '
        'cancelling the token, so a handler awaiting `cancelled` parks forever',
      ),
    );
    expect(
      how,
      startsWith('cancelled:'),
      reason:
          'the handler must unwind through cancellation, not through the test '
          'release hatch',
    );
  });

  // CONTROL: the sibling path already did this, and must keep doing it. If the
  // two ever disagree again, this is the pair that says so.
  test('CONTROL: drain() cancels the token too', () async {
    await startInFlightCall();

    unawaited(responder.drain(timeout: const Duration(seconds: 2)));

    final how = await service.ended.future.timeout(const Duration(seconds: 5));
    expect(how, startsWith('cancelled:'));
  });

  // GUARD: cancelling on the way out must not make close() itself throw or
  // hang, and it must stay callable twice -- an owner closes, and so does the
  // server that built the endpoint.
  test('GUARD: close() stays idempotent and does not throw', () async {
    await startInFlightCall();

    await responder.close().timeout(const Duration(seconds: 5));
    await responder.close().timeout(const Duration(seconds: 5));
  });
}
