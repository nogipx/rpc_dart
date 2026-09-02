// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ClientStreamCaller.finishSending() waited with a HARDCODED 60s:
//
//   return await _responseCompleter.future.timeout(const Duration(seconds: 60), ...)
//
// UnaryCaller has always used `timeout ?? remainingTime ?? 60s`, so a deadline
// LONGER than a minute was honoured there and silently truncated here.
// Measured against a server that never responds, with a 90s deadline:
//
//   unary        -> TimeoutException after 90s
//   clientStream -> TimeoutException after 60s
//
// A streaming upload given ten minutes died after one. After the fix the
// client stream runs the full 90s and reports RpcDeadlineExceededException --
// the scope's deadline path wins once the premature timeout stops firing.
//
// ON TEST SPEED: only a deadline ABOVE the old 60s fallback distinguishes the
// two, so the direct witness cannot run in under a minute. It is kept below,
// skipped, so the reproduction stays in the repo and can be run on demand:
//
//   dart test test/streams/client_stream_long_deadline_test.dart --run-skipped
//
// The unskipped tests pin everything that is observable quickly: that a
// deadline is honoured, that the no-deadline fallback still applies, and that
// the ordinary response path is untouched.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      handler: (requests, {RpcContext? context}) async {
        final seen = <String>[];
        await for (final r in requests) {
          seen.add(r.value);
        }
        return seen.join(',').rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Never returns: the caller's own bound is what ends the call.
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'blackhole',
      handler: (requests, {RpcContext? context}) async {
        await for (final _ in requests) {}
        await Completer<void>().future;
        return 'never'.rpc;
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

Future<RpcString> _call(_Rig rig, String method, RpcContext? ctx) {
  final requests = StreamController<RpcString>();
  requests.add('a'.rpc);
  unawaited(requests.close());
  return rig.caller.clientStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: method,
    requestCodec: _codec,
    responseCodec: _codec,
    context: ctx,
  )(requests.stream);
}

void main() {
  test('a short deadline is honoured', () async {
    final rig = _connect();
    final sw = Stopwatch()..start();

    await expectLater(
      _call(
        rig,
        'blackhole',
        RpcContext.withTimeout(const Duration(milliseconds: 400)),
      ).timeout(const Duration(seconds: 5)),
      throwsA(
        anyOf(isA<RpcDeadlineExceededException>(), isA<TimeoutException>()),
      ),
    );

    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(3000),
      reason: 'the call ran well past its 400ms deadline',
    );
    await _teardown(rig);
  });

  test('a response inside the deadline is returned normally', () async {
    final rig = _connect();
    expect(
      await _call(
        rig,
        'collect',
        RpcContext.withTimeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 5)),
      isA<RpcString>().having((r) => r.value, 'value', 'a'),
    );
    await _teardown(rig);
  });

  test('no deadline still returns normally', () async {
    // The 60s fallback path: unchanged for a call with no deadline of its own.
    final rig = _connect();
    expect(
      (await _call(
        rig,
        'collect',
        null,
      ).timeout(const Duration(seconds: 5))).value,
      'a',
    );
    await _teardown(rig);
  });

  test(
    'a deadline longer than the 60s fallback is not truncated',
    () async {
      // The direct witness. Pre-fix this fails at ~60s with TimeoutException;
      // post-fix it runs the full 90s.
      final rig = _connect();
      final sw = Stopwatch()..start();

      await expectLater(
        _call(
          rig,
          'blackhole',
          RpcContext.withTimeout(const Duration(seconds: 90)),
        ),
        throwsA(
          anyOf(isA<RpcDeadlineExceededException>(), isA<TimeoutException>()),
        ),
      );

      sw.stop();
      expect(
        sw.elapsed.inSeconds,
        greaterThan(75),
        reason:
            'the 90s deadline was truncated to the 60s fallback '
            '(ended after ${sw.elapsed.inSeconds}s)',
      );
      await _teardown(rig);
    },
    timeout: const Timeout(Duration(seconds: 200)),
    skip:
        'Takes ~90s by construction: only a deadline above the old 60s '
        'fallback distinguishes the bug. Run with --run-skipped.',
  );
}
