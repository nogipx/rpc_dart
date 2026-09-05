// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A WebSocket close CODE is the only thing a peer can say about why it hung
// up, and it was discarded. Every close reached the caller as the same
// synthesized `UNAVAILABLE: Stream closed without receiving response`.
//
// Measured against a real dart:io server closing mid-call, before the fix:
//
//   1001 going away       -> UNAVAILABLE Stream closed without receiving response
//   1008 policy violation -> UNAVAILABLE Stream closed without receiving response
//   1009 message too big  -> UNAVAILABLE Stream closed without receiving response
//   1011 internal error   -> UNAVAILABLE Stream closed without receiving response
//
// UNAVAILABLE is RETRYABLE, so this did not merely lose information: it made
// clients retry deterministic failures. A server that hung up for a policy
// violation, or on its own internal error, was retried maxAttempts times and
// could never have succeeded.
//
// Two hops had to change, and hop-by-hop measurement is what found the second.
// The channel mapped the code correctly and the transport carried it, and then
// it was replaced one hop from the caller:
//
//   channel  .incoming         : RpcStatusException(7)
//   transport.incomingMessages : RpcStatusException(7)
//   the pending call           : RpcStatusException(14) Stream closed ...
//
// because per-stream views are dedicated controllers and a connection-level
// error only ever reached the broadcast. RpcChannelTransport now delivers it
// to the calls it killed, which fixes this for every channel transport
// (websocket, isolate, wasm).

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void main() {
  late HttpServer http;
  late Uri uri;
  int closeWith = 1000;

  setUp(() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.transform(WebSocketTransformer()).listen((ws) {
      ws.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
      // Hang up mid-call, which is the moment that matters.
      Timer(const Duration(milliseconds: 300), () {
        ws.close(closeWith, 'server said $closeWith');
      });
    });
    uri = Uri.parse('ws://127.0.0.1:${http.port}');
  });

  tearDown(() => http.close(force: true));

  /// Makes one call against a server that will close with [code].
  Future<Object?> callWhileServerCloses(int code) async {
    closeWith = code;
    final transport = await RpcWebSocketCallerTransport.connect(uri);
    final caller = RpcCallerEndpoint(transport: transport);
    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 6));
      return null;
    } catch (e) {
      return e;
    } finally {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
    }
  }

  test('a policy-violation close is not reported as retryable', () async {
    final error = await callWhileServerCloses(1008);
    expect(error, isA<RpcStatusException>());
    final status = (error! as RpcStatusException).statusCode;
    expect(
      status,
      RpcStatus.permissionDenied,
      reason:
          'this arrived as UNAVAILABLE, which RpcRetryInterceptor retries -- '
          'so a client hammered a server that had rejected it on policy '
          'grounds and could never succeed',
    );
    expect(status, isNot(RpcStatus.unavailable));
  });

  test('a server internal-error close is not reported as retryable', () async {
    final error = await callWhileServerCloses(1011);
    expect((error! as RpcStatusException).statusCode, RpcStatus.internal);
  });

  test('message-too-big maps to RESOURCE_EXHAUSTED', () async {
    final error = await callWhileServerCloses(1009);
    expect(
      (error! as RpcStatusException).statusCode,
      RpcStatus.resourceExhausted,
    );
  });

  test('an application close code is UNKNOWN, not a guess', () async {
    // 4000-4999 are private-use: the peer said something gRPC has no word for.
    final error = await callWhileServerCloses(4001);
    expect((error! as RpcStatusException).statusCode, RpcStatus.unknown);
  });

  test('the close code and reason reach the caller', () async {
    final error = await callWhileServerCloses(1008);
    final status = error! as RpcStatusException;
    expect(status.message, contains('1008'));
    expect(status.message, contains('server said 1008'));
  });

  test('GUARD: an orderly close still ends the call as UNAVAILABLE', () async {
    // 1000/1001 are a goodbye, not a fault. They must keep producing the
    // ordinary connection-lost status, which IS retryable -- a draining load
    // balancer is exactly what a client should retry past.
    for (final code in [1000, 1001]) {
      final error = await callWhileServerCloses(code);
      expect(
        (error! as RpcStatusException).statusCode,
        RpcStatus.unavailable,
        reason: 'close $code is a clean shutdown',
      );
    }
  });

  group('the mapping table', () {
    test('separates transient from deterministic', () {
      // Retryable: connection-level and the peer asking for backoff.
      for (final code in [null, 1000, 1001, 1005, 1006, 1012, 1013, 1014]) {
        expect(
          grpcStatusFromWebSocketCloseCode(code),
          RpcStatus.unavailable,
          reason: 'close $code is transient',
        );
      }
      // Deterministic: retrying cannot help.
      expect(
        grpcStatusFromWebSocketCloseCode(1008),
        RpcStatus.permissionDenied,
      );
      expect(
        grpcStatusFromWebSocketCloseCode(1009),
        RpcStatus.resourceExhausted,
      );
      for (final code in [1002, 1003, 1007, 1010, 1011]) {
        expect(
          grpcStatusFromWebSocketCloseCode(code),
          RpcStatus.internal,
          reason: 'close $code is a protocol or server fault',
        );
      }
      // Private/library ranges carry no agreed meaning.
      expect(grpcStatusFromWebSocketCloseCode(3001), RpcStatus.unknown);
      expect(grpcStatusFromWebSocketCloseCode(4001), RpcStatus.unknown);
    });

    test('GUARD: "the peer said nothing" codes stay silent', () async {
      // 1005/1006 mean no code was received at all. They must NOT raise a
      // channel error: that is the ordinary dropped-socket path reconnect()
      // re-attaches on, and raising there broke three reconnect tests -- which
      // is what narrowed the rule to "only when the peer actually said
      // something".
      expect(grpcStatusFromWebSocketCloseCode(1005), RpcStatus.unavailable);
      expect(grpcStatusFromWebSocketCloseCode(1006), RpcStatus.unavailable);
    });
  });
}
