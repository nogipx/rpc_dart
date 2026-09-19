// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-53: an RST_STREAM landing while the server is still writing responses for
// that stream used to kill the WHOLE connection -- every other call on it then
// failed with "HTTP/2 connection ... is no longer active". Rounds 385 and 387
// ablated it down to the reset itself and placed the cause below rpc_dart,
// inside package:http2's handling of a response written to a stream the client
// has just cancelled. http2 3.1.0 fixes it ("gracefully handle receiving
// headers on a stream that the client has canceled", #1799), which is why the
// floor in pubspec.yaml is ^3.1.0 and this file guards it.
//
// Measured with the probe this is derived from
// (.dart_tool/probe/abort_kills_the_connection.dart), same code both sides,
// only the resolved http2 version differing:
//
//   arm                                 2.3.1        3.1.0
//   abort racing responses, awaited     5 of 5 DEAD  5 of 5 pong
//   abort racing responses, unawaited   5 of 5 DEAD  5 of 5 pong
//   abortWhileEmitting (30 ms settle)   5 of 5 pong  5 of 5 pong
//   abortWhenIdle                       5 of 5 pong  5 of 5 pong
//   halfClose (control)                 5 of 5 pong  5 of 5 pong
//
// The RACE is the whole experiment: the two dead arms differ from
// `abortWhileEmitting` only in NOT settling for 30 ms before the abort. A
// version of this that settles passes on both and witnesses nothing.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    // Answers every request, so a reset can land while it is writing.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Says nothing at all: a reset with no response in flight.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'silent',
      handler: (requests, {RpcContext? context}) async* {
        await for (final _ in requests) {
          // consume, answer nothing
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  const calls = 5;

  late RpcHttp2Server server;
  late RpcHttp2CallerTransport client;
  late RpcCallerEndpoint caller;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: LogScope.noop,
    );
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    await client.close();
    await server.stop();
  });

  /// The connection check. Reports rather than throws, so a failure names which
  /// call killed it instead of dying at the first one.
  Future<String> ping() async {
    try {
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'ping',
            request: '?'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
      return r.value;
    } on TimeoutException {
      return 'HUNG';
    } catch (e) {
      return e is RpcStatusException ? 'DEAD(${e.message})' : 'DEAD($e)';
    }
  }

  /// [settle] is the discriminator: with it the reset lands after the responses
  /// have drained, without it the two race.
  Future<List<String>> drive(
    String method, {
    required bool abort,
    required bool settle,
  }) async {
    final pings = <String>[];
    for (var i = 0; i < calls; i++) {
      final c = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'Svc',
        methodName: method,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      c.responses.listen((_) {}, onError: (Object _) {});
      await c.send('a'.rpc);
      await c.send('b'.rpc);
      if (settle) await Future<void>.delayed(const Duration(milliseconds: 30));
      if (abort) {
        await c.abort('test');
      } else {
        await c.finishSending();
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pings.add(await ping());
    }
    return pings;
  }

  // WITNESS: every one of these was DEAD on http2 2.3.1, from the first call.
  test('an abort racing the responses leaves the connection usable', () async {
    final pings = await drive('echo', abort: true, settle: false);
    expect(
      pings,
      List.filled(calls, 'pong'),
      reason:
          'a reset landing while the server writes used to take the whole '
          'connection with it, so every later call on it failed',
    );
  });

  // GUARD: passed on both versions. The reset is still delivered and must
  // still not hurt when nothing is in flight.
  test('an abort with the responses drained is unchanged', () async {
    final pings = await drive('echo', abort: true, settle: true);
    expect(pings, List.filled(calls, 'pong'));
  });

  test('an abort of a silent handler is unchanged', () async {
    final pings = await drive('silent', abort: true, settle: false);
    expect(pings, List.filled(calls, 'pong'));
  });

  test('CONTROL: the same call ended properly', () async {
    final pings = await drive('echo', abort: false, settle: false);
    expect(pings, List.filled(calls, 'pong'));
  });
}
