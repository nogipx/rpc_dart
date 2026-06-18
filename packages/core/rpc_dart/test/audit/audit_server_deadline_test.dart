// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The server now enforces the client's grpc-timeout deadline: it arms a timer
/// and cancels the handler's cancellation token when the deadline passes (Dart
/// cannot preempt a bare `await`, but cooperative handlers and request-stream
/// readers unwind). A normal call within the deadline must still succeed.
void main() {
  group('server deadline enforcement', () {
    test('cooperative handler is cancelled when the deadline passes', () async {
      final (clientT, serverT) = RpcChannelTransport.memoryPair();
      final server = RpcResponderEndpoint(transport: serverT);
      final client = RpcCallerEndpoint(transport: clientT);
      final probe = _Probe();
      server.registerServiceContract(_DeadlineContract(probe));
      server.start();
      final caller = _DeadlineCaller(client);

      try {
        await caller.slow(
          _Msg('x'),
          context: RpcContext.withTimeout(const Duration(milliseconds: 120)),
        );
      } catch (_) {
        // Client surfaces its own timeout; we only care about the server.
      }
      // Give the handler time to observe the cancellation and unwind.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(probe.slowOutcome, 'cancelled');
      expect(probe.cancelReason, 'deadline exceeded');

      await client.close();
      await server.close();
    });

    test('a call that completes within the deadline succeeds', () async {
      final (clientT, serverT) = RpcChannelTransport.memoryPair();
      final server = RpcResponderEndpoint(transport: serverT);
      final client = RpcCallerEndpoint(transport: clientT);
      server.registerServiceContract(_DeadlineContract(_Probe()));
      server.start();
      final caller = _DeadlineCaller(client);

      final r = await caller.fast(
        _Msg('hi'),
        context: RpcContext.withTimeout(const Duration(seconds: 5)),
      );
      expect(r.value, 'ok:hi');

      await client.close();
      await server.close();
    });
  });
}

class _Probe {
  String slowOutcome = 'none';
  String? cancelReason;
}

final class _Msg implements IRpcSerializable {
  final String value;
  const _Msg(this.value);
  factory _Msg.fromJson(Map<String, dynamic> j) => _Msg(j['v'] as String);
  @override
  Map<String, dynamic> toJson() => {'v': value};
  static RpcCodec<_Msg> get codec => RpcCodec(_Msg.fromJson);
}

final class _DeadlineContract extends RpcResponderContract {
  final _Probe probe;
  _DeadlineContract(this.probe) : super('S');

  @override
  void setup() {
    addUnaryMethod<_Msg, _Msg>(
      methodName: 'fast',
      handler: (m, {context}) async => _Msg('ok:${m.value}'),
      requestCodec: _Msg.codec,
      responseCodec: _Msg.codec,
    );
    addUnaryMethod<_Msg, _Msg>(
      methodName: 'slow',
      handler: (m, {context}) async {
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          final token = context?.cancellationToken;
          if (token?.isCancelled == true) {
            probe.slowOutcome = 'cancelled';
            probe.cancelReason = token!.reason;
            throw StateError('cancelled');
          }
        }
        probe.slowOutcome = 'ran-full';
        return _Msg('done');
      },
      requestCodec: _Msg.codec,
      responseCodec: _Msg.codec,
    );
  }
}

final class _DeadlineCaller extends RpcCallerContract {
  _DeadlineCaller(RpcCallerEndpoint endpoint) : super('S', endpoint);

  Future<_Msg> fast(_Msg m, {RpcContext? context}) => callUnary<_Msg, _Msg>(
    methodName: 'fast',
    request: m,
    requestCodec: _Msg.codec,
    responseCodec: _Msg.codec,
    context: context,
  );

  Future<_Msg> slow(_Msg m, {RpcContext? context}) => callUnary<_Msg, _Msg>(
    methodName: 'slow',
    request: m,
    requestCodec: _Msg.codec,
    responseCodec: _Msg.codec,
    context: context,
  );
}
