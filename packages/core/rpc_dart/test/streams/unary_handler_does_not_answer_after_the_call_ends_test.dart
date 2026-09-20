// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `UnaryResponder` answered calls that were already over.
//
// `StreamProcessor` gates `send`, `sendError` and `finishSending` on
// `_isActive`, so no streaming shape can emit after its call ends. The codec
// unary responder is not on that path and had no equivalent: every
// cancellation check in the file sat BEFORE the handler ran, and the monitor it
// installs only cancels the INBOUND subscription. So for the whole duration of
// the handler -- the only slow part of a unary call -- a cancel, a deadline, a
// `drain()` or an `endpoint.close()` went unobserved, and when the handler
// returned a DATA frame and `grpc-status: 0` went out on a stream the caller
// had abandoned.
//
// Drain is the case that decides it: it exists so a rolling deploy can stop
// cleanly, and a stream reporting OK after the window is the one thing the
// window is there to prevent.
//
// The finding was the ASYMMETRY. The identical handler was suppressed under
// every streaming shape and under the zero-copy unary branch, and answered
// under codec unary; one of the two positions had to be wrong for all of them.

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

/// A handler that finishes only when the test lets it -- and IGNORES the token,
/// which is the point. A cooperative handler would unwind on its own; this is
/// the one that has to be stopped at the door.
final class _StubbornService extends RpcResponderContract {
  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();

  _StubbornService() : super('Stubborn');

  @override
  void setup() {
    addUnaryMethod<_Req, _Resp>(
      methodName: 'Work',
      handler: (request, {context}) async {
        if (!started.isCompleted) started.complete();
        await finish.future;
        return _Resp('done anyway');
      },
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
    );
  }
}

void main() {
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;
  late _StubbornService service;

  setUp(() {
    final pair = RpcInMemoryTransport.pair();
    caller = RpcCallerEndpoint(transport: pair.$1);
    responder = RpcResponderEndpoint(transport: pair.$2);
    service = _StubbornService();
    responder.registerServiceContract(service);
    responder.start();
  });

  tearDown(() async {
    if (!service.finish.isCompleted) service.finish.complete();
    await caller.close();
    await responder.close();
  });

  /// Starts a call and returns once its handler is running.
  Future<Future<_Resp>> startCall() async {
    final call = caller
        .unaryRequest<_Req, _Resp>(
          serviceName: 'Stubborn',
          methodName: 'Work',
          request: _Req('x'),
          requestCodec: RpcCodec<_Req>(_Req.fromJson),
          responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
        )
        .catchError((Object _) => _Resp('caller gave up'));
    await service.started.future.timeout(const Duration(seconds: 5));
    return call;
  }

  test(
    'a drained call gets no answer when its handler finally returns',
    () async {
      final call = await startCall();

      // Drain, which cancels the handler's token. The handler ignores it.
      unawaited(responder.drain(timeout: const Duration(seconds: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Now let the handler finish. Before the fix this sent a payload and
      // `grpc-status: 0` on a stream the drain had already closed out.
      service.finish.complete();

      final result = await call.timeout(const Duration(seconds: 5));
      expect(
        result.value,
        isNot('done anyway'),
        reason:
            'the drain window exists to stop exactly this: a handler that '
            'outlived it must not report success to the caller',
      );
    },
  );

  // CONTROL: the gate must only close on a call that actually ended. An
  // ordinary call still gets its answer.
  test('CONTROL: an undisturbed call is answered normally', () async {
    final call = await startCall();

    service.finish.complete();

    final result = await call.timeout(const Duration(seconds: 5));
    expect(result.value, 'done anyway');
  });

  // GUARD: suppressing the send must not strand the caller. It learns the call
  // ended rather than waiting out its own deadline.
  test('GUARD: the caller is not left hanging', () async {
    final call = await startCall();

    unawaited(responder.drain(timeout: const Duration(seconds: 2)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    service.finish.complete();

    await call.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the caller never completed: dropping the response must not mean '
        'dropping the call',
      ),
    );
  });
}
