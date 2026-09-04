// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketServer.start() set `_isRunning = true` BEFORE listening to the
// connections stream. When that listen threw, the server was left claiming to
// run with no subscription at all.
//
// It throws on the ordinary restart path, because the server does not own its
// connections stream and `HttpServer.transform(WebSocketTransformer())` is
// single-subscription: stop() cancels the subscription, and start() cannot
// listen again.
//
// Measured, start / stop / start over such a stream:
//
//   before: StateError "Stream has already been listened to", isRunning TRUE,
//           and the next client call HUNG until its own timeout
//   after : the error names the cause and the remedy, and isRunning is false
//
// A server reporting healthy while accepting nothing is worse than one that
// failed -- nothing upstream can tell there is anything to fix. RpcHttp2Server
// restarts fine because it rebinds its own socket; this one cannot, and now
// says so.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  }
}

RpcWebSocketServer _serverOver(Stream<WebSocketChannel> connections) =>
    RpcWebSocketServer(
      connections: connections,
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );

void main() {
  group('restart over a single-subscription source', () {
    late StreamController<WebSocketChannel> source;
    late RpcWebSocketServer server;

    setUp(() {
      source = StreamController<WebSocketChannel>();
      server = _serverOver(source.stream);
      addTearDown(source.close);
    });

    test('a failed restart leaves isRunning false', () async {
      await server.start();
      expect(server.isRunning, isTrue);
      await server.stop();
      expect(server.isRunning, isFalse);

      await expectLater(server.start(), throwsStateError);

      expect(
        server.isRunning,
        isFalse,
        reason:
            'the flag was set before the listen that threw, so the server '
            'claimed to be running with no subscription and client calls hung',
      );
    });

    test('the failure says what went wrong and what to do', () async {
      await server.start();
      await server.stop();

      await expectLater(
        server.start(),
        throwsA(
          isA<StateError>()
              .having(
                (e) => e.message,
                'message',
                contains('cannot be restarted'),
              )
              .having((e) => e.message, 'message', contains('broadcast')),
        ),
        reason:
            '"Stream has already been listened to" names a Dart rule, not the '
            'mistake',
      );
    });

    test('stop() after a failed restart is a safe no-op', () async {
      await server.start();
      await server.stop();
      await expectLater(server.start(), throwsStateError);

      // GUARD: with the flag left true, this used to walk the teardown path of
      // a server that had never started.
      await expectLater(server.stop(), completes);
      expect(server.isRunning, isFalse);
    });
  });

  group('the ordinary paths are unaffected', () {
    test('start / stop / start over a broadcast source still serves', () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => http.close(force: true));
      final connections = http
          .transform(WebSocketTransformer())
          .map<WebSocketChannel>(IOWebSocketChannel.new)
          .asBroadcastStream();

      final server = _serverOver(connections);
      addTearDown(server.stop);

      Future<String> callOnce() async {
        final client = await RpcWebSocketCallerTransport.connect(
          Uri.parse('ws://127.0.0.1:${http.port}'),
        );
        final caller = RpcCallerEndpoint(transport: client);
        try {
          final r = await caller
              .unaryRequest<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'echo',
                request: 'x'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .timeout(const Duration(seconds: 10));
          return r.value;
        } finally {
          await caller.close();
          await client.close();
        }
      }

      await server.start();
      expect(await callOnce(), 'echo-ok');

      await server.stop();
      await server.start();
      expect(server.isRunning, isTrue);
      expect(await callOnce(), 'echo-ok', reason: 'restart must still serve');
    });

    test('start() twice is a no-op, not a second subscription', () async {
      final source = StreamController<WebSocketChannel>();
      addTearDown(source.close);
      final server = _serverOver(source.stream);
      addTearDown(server.stop);

      await server.start();
      await expectLater(server.start(), completes);
      expect(server.isRunning, isTrue);
    });

    test('stop() before any start is a no-op', () async {
      // Broadcast on purpose: closing a never-listened single-subscription
      // controller does not complete until someone listens, and this server
      // never listens -- that would hang the teardown, not the library.
      final source = StreamController<WebSocketChannel>.broadcast();
      addTearDown(source.close);
      final server = _serverOver(source.stream);

      await expectLater(server.stop(), completes);
      expect(server.isRunning, isFalse);
    });
  });
}
