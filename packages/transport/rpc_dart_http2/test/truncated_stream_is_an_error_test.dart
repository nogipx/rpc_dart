// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// package:http2 completes a stream's `incomingMessages` NORMALLY when the
// connection goes away mid-response, so the caller's `onDone` could not tell a
// finished call from a truncated one -- and it emitted a clean end-of-stream
// either way.
//
// A server stream cut off by a dead peer was therefore delivered to the
// consumer as a NORMAL completion: partial data reported as complete, with no
// error anywhere. A client paging through results would simply believe it had
// them all.
//
// Found by running one battery across the transports and comparing. Same
// scenario, two calls in flight, server stopped:
//
//   websocket : errors=[RpcStatusException]  done=true
//   http2     : errors=[]                    done=true   <-- the odd one
//
// The unary case was already correct on both (UNAVAILABLE), because core's
// unary caller treats "stream closed without a response" as an error. Only a
// call that had already produced output could be silently truncated.
//
// The rule is the gRPC one: a response that ends without a grpc-status has not
// been answered. Trailers-Only responses carry the status on the first HEADERS
// frame, so the check keys on the header, not on the frame's position.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Uint8List _framed(String text) =>
    RpcMessageFrame.encode(_codec.serialize(text.rpc), compressed: false);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'drip',
      handler: (request, {RpcContext? context}) async* {
        var i = 0;
        while (true) {
          yield 'item-${i++}'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'three',
      handler: (request, {RpcContext? context}) async* {
        yield 'a'.rpc;
        yield 'b'.rpc;
        yield 'c'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a server stream cut off mid-flight surfaces an error', () async {
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
    });

    final items = <String>[];
    final errors = <Object>[];
    var done = false;
    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'drip',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen(
          (m) => items.add(m.value),
          onError: errors.add,
          onDone: () => done = true,
        );
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(items, isNotEmpty, reason: 'the stream must be flowing first');

    await server.stop();
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      errors,
      isNotEmpty,
      reason:
          'the stream ended without trailers, so the consumer was handed a '
          'clean completion and could not tell partial data from complete',
    );
    expect(errors.first, isA<RpcStatusException>());
    expect(
      (errors.first as RpcStatusException).statusCode,
      RpcStatus.unavailable,
    );
    expect(done, isTrue, reason: 'the stream must still terminate');
  });

  test('GUARD: an ordinary server stream still completes cleanly', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );
    await server.start();
    addTearDown(server.stop);
    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    // Repeated, because the status bookkeeping is per stream and must be
    // retired: a leak would make the SECOND call look truncated.
    for (var round = 0; round < 5; round++) {
      final items = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'three',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((m) => m.value)
          .toList()
          .timeout(const Duration(seconds: 10));
      expect(items, ['a', 'b', 'c'], reason: 'round $round');
    }
  });

  test('GUARD: a Trailers-Only response is not treated as truncated', () async {
    // The status arrives on the FIRST headers frame here, so a check keyed on
    // "trailers came after initial headers" would call this truncated.
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(socket.close);
    socket.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      conn.incomingStreams.listen((stream) {
        stream.incomingMessages.listen((_) {}, onError: (Object _) {});
        stream.sendHeaders([
          http2.Header.ascii(':status', '200'),
          http2.Header.ascii('content-type', 'application/grpc+proto'),
          http2.Header.ascii('grpc-status', '5'),
          http2.Header.ascii('grpc-message', 'nope'),
        ], endStream: true);
      }, onError: (Object _) {});
    }, onError: (Object _) {});

    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    Object? seen;
    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'whatever',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      seen = e;
    }

    expect(
      seen,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.notFound,
      ),
      reason:
          'the peer said NOT_FOUND on a Trailers-Only response; reporting '
          'UNAVAILABLE instead would replace the real status with a made-up one',
    );
  });

  test(
    'GUARD: a well-formed response over a raw peer still succeeds',
    () async {
      final socket = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(socket.close);
      socket.listen((client) {
        final conn = http2.ServerTransportConnection.viaSocket(client);
        conn.incomingStreams.listen((stream) {
          stream.incomingMessages.listen((_) {}, onError: (Object _) {});
          stream.sendHeaders([
            http2.Header.ascii(':status', '200'),
            http2.Header.ascii('content-type', 'application/grpc+proto'),
          ]);
          stream.sendData(_framed('pong'));
          stream.sendHeaders([
            http2.Header.ascii('grpc-status', '0'),
          ], endStream: true);
        }, onError: (Object _) {});
      }, onError: (Object _) {});

      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: socket.port,
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await client.close();
      });

      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(r.value, 'pong');
    },
  );
}
