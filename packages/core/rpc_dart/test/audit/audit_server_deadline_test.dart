// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The server enforces the client's grpc-timeout deadline: it arms a timer
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
      final deadline = Completer<void Function()>();
      Timer? deadlineTimer;
      runZoned(
        server.start,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration >= const Duration(minutes: 4) &&
                duration <= const Duration(minutes: 5)) {
              deadlineTimer = timer;
              deadline.complete(() {
                timer.cancel();
                zone.run(callback);
              });
            }
            return timer;
          },
        ),
      );
      addTearDown(() async {
        deadlineTimer?.cancel();
        await client.close();
        await server.close();
      });
      final caller = _DeadlineCaller(client);

      final call = expectLater(
        caller.slow(
          _Msg('x'),
          context: RpcContext.empty().withTimeout(const Duration(minutes: 5)),
        ),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
      final token = await probe.started.future.timeout(
        const Duration(seconds: 5),
      );
      expect(token.isCancelled, isFalse);

      // Fire the server's deadline after dispatch, independently of the
      // caller's timer and of how long startup takes under load.
      final expire = await deadline.future.timeout(const Duration(seconds: 5));
      expire();
      expect(
        await probe.cancelled.future.timeout(const Duration(seconds: 5)),
        'deadline exceeded',
      );
      await call;
    });

    test('a call that completes within the deadline succeeds', () async {
      final (clientT, serverT) = RpcChannelTransport.memoryPair();
      final server = RpcResponderEndpoint(transport: serverT);
      final client = RpcCallerEndpoint(transport: clientT);
      addTearDown(() async {
        await client.close();
        await server.close();
      });
      server.registerServiceContract(_DeadlineContract(_Probe()));
      server.start();
      final caller = _DeadlineCaller(client);

      final r = await caller.fast(
        _Msg('hi'),
        context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
      );
      expect(r.value, 'ok:hi');
    });
  });
}

class _Probe {
  final started = Completer<RpcCancellationToken>();
  final cancelled = Completer<String?>();
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
        final token = context!.cancellationToken!;
        probe.started.complete(token);
        await token.cancelled;
        probe.cancelled.complete(token.reason);
        token.throwIfCancelled();
        return m;
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
