// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The HTTP/2 caller killed its own connection after a handful of calls.
//
// releaseStreamId() ended with `stream.sendData(Uint8List(0), endStream: true)`
// -- but by the time the pipeline releases an id the request direction is
// already finished, because every call ends with END_STREAM. So that was a DATA
// frame on a half-closed (local) stream, which HTTP/2 forbids and package:http2
// answers by tearing down the whole CONNECTION, not just the stream. The
// try/catch around it never fired: the violation surfaces asynchronously from
// the connection's own state machine.
//
// Measured on a default client/server pair over ONE connection:
//
//   before: 4 of 40 sequential unary calls, then "HTTP/2 error: Connection
//           error: Connection is being forcefully terminated"
//           and 0 of 8 concurrent rounds, with "The http/2 connection is no
//           longer active and can therefore not be used to make new streams"
//   after : 40 of 40 and 8 of 8
//
// Nothing caught it because the suite builds a fresh connection per test and
// makes only a few calls on it -- the exact shape that hides a per-connection
// defect.
//
// finishSending() had the same hazard from the other direction: a caller that
// already passed `endStream: true` to sendMessage would send a second
// END_STREAM. It is idempotent now, like RpcChannelTransport.finishSending.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'count',
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < 3; i++) {
          yield 'item-$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// One server plus one client transport, sharing a single connection.
Future<({RpcCallerEndpoint caller, RpcHttp2CallerTransport client})>
_connect() async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
  );
  await server.start();

  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
  );
  final caller = RpcCallerEndpoint(transport: client);

  addTearDown(() async {
    await caller.close();
    await client.close();
    await server.stop();
  });

  return (caller: caller, client: client);
}

Future<Object> _echo(RpcCallerEndpoint caller) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .then<Object>((r) => r.value, onError: (Object e) => e);

void main() {
  test('40 sequential calls share one connection', () async {
    final c = await _connect();

    for (var i = 0; i < 40; i++) {
      expect(
        await _echo(c.caller),
        'echo-ok',
        reason:
            'call $i failed; releasing a stream used to send DATA on a stream '
            'already half-closed, which terminates the whole connection',
      );
    }
  });

  test('8 rounds of 5 concurrent calls share one connection', () async {
    final c = await _connect();

    for (var round = 0; round < 8; round++) {
      final batch = await Future.wait([
        for (var i = 0; i < 5; i++) _echo(c.caller),
      ]);
      expect(
        batch,
        everyElement('echo-ok'),
        reason: 'round $round failed on a connection earlier rounds used',
      );
    }
  });

  test('a server stream still completes, and the connection survives', () async {
    // GUARD: a call whose request direction is closed early but whose response
    // keeps arriving is exactly the shape the release path has to leave alone.
    final c = await _connect();

    for (var round = 0; round < 5; round++) {
      final items = await c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'count',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((m) => m.value)
          .toList();
      expect(items, ['item-0', 'item-1', 'item-2'], reason: 'round $round');
    }

    // The connection must still serve a plain call afterwards.
    expect(await _echo(c.caller), 'echo-ok');
  });

  test('the transport does not leak per-stream state across calls', () async {
    // GUARD against the obvious wrong fix: never cleaning up would also keep
    // the connection alive while growing a set per call forever.
    final c = await _connect();

    for (var i = 0; i < 20; i++) {
      await _echo(c.caller);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final details = (await c.client.health()).details;
    expect(details['activeStreams'], 0);
    expect(details['pendingSubscriptions'], 0);
    expect(details['pendingParsers'], 0);
  });
}
