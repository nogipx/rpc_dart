// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Full typed RPC contract end-to-end over a REAL dart:io WebSocket server.
//
// Existing websocket tests exercise the raw transport (createStream /
// sendMessage / sendMetadata / incomingMessages) over a real or in-memory
// socket. This suite drives the full endpoint/contract stack
// (RpcCallerEndpoint / RpcResponderEndpoint via RpcWebSocketServer) over an
// ephemeral localhost WebSocket connection for every RPC method kind:
// unary, server-stream, client-stream, bidirectional, typed error
// propagation, mid-stream cancellation, concurrency and high-volume ordering.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ============================================================================
// Models (codec-based so we exercise byte-exact serialization over the wire)
// ============================================================================

class EchoRequest implements IRpcSerializable {
  final String text;
  final int count;

  const EchoRequest(this.text, {this.count = 1});

  @override
  Map<String, dynamic> toJson() => {'text': text, 'count': count};

  static EchoRequest fromJson(Map<String, dynamic> json) =>
      EchoRequest(json['text'] as String, count: json['count'] as int);
}

class EchoResponse implements IRpcSerializable {
  final String text;
  final int index;

  const EchoResponse(this.text, this.index);

  @override
  Map<String, dynamic> toJson() => {'text': text, 'index': index};

  static EchoResponse fromJson(Map<String, dynamic> json) =>
      EchoResponse(json['text'] as String, json['index'] as int);
}

const _reqCodec = RpcCodec<EchoRequest>(EchoRequest.fromJson);
const _resCodec = RpcCodec<EchoResponse>(EchoResponse.fromJson);

const serviceName = 'ws.Contract';

// ============================================================================
// Server-side contract
// ============================================================================

final class _ContractResponder extends RpcResponderContract {
  _ContractResponder()
    : super(serviceName, dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    // Unary: echo with count, plus a trigger for typed error propagation.
    addUnaryMethod<EchoRequest, EchoResponse>(
      methodName: 'Unary',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: (req, {context}) async {
        if (req.text == 'BOOM') {
          throw RpcStatusException(
            RpcStatus.invalidArgument,
            'responder rejected: BOOM',
          );
        }
        return EchoResponse('reply:${req.text}', req.count);
      },
    );

    // Server stream: emits [count] ordered responses.
    addServerStreamMethod<EchoRequest, EchoResponse>(
      methodName: 'ServerStream',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: (req, {context}) async* {
        for (var i = 0; i < req.count; i++) {
          yield EchoResponse(req.text, i);
        }
      },
    );

    // Server stream that never completes unless cancelled -- used to verify
    // mid-stream cancel tears down cleanly without hanging.
    addServerStreamMethod<EchoRequest, EchoResponse>(
      methodName: 'InfiniteStream',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: (req, {context}) async* {
        var i = 0;
        while (true) {
          yield EchoResponse(req.text, i++);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
    );

    // Client stream: collects all requests, returns the aggregate.
    addClientStreamMethod<EchoRequest, EchoResponse>(
      methodName: 'ClientStream',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: (requests, {context}) async {
        final buffer = <String>[];
        await for (final r in requests) {
          buffer.add(r.text);
        }
        return EchoResponse(buffer.join(','), buffer.length);
      },
    );

    // Bidirectional: echo each request back, preserving order.
    addBidirectionalMethod<EchoRequest, EchoResponse>(
      methodName: 'BidiStream',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: (requests, {context}) async* {
        var i = 0;
        await for (final r in requests) {
          yield EchoResponse('echo:${r.text}', i++);
        }
      },
    );
  }
}

// ============================================================================
// Test harness: ephemeral dart:io WS server feeding RpcWebSocketServer.
// ============================================================================

class _Harness {
  _Harness(this._httpServer, this._connCtl, this._rpcServer);

  final HttpServer _httpServer;
  final StreamController<WebSocketChannel> _connCtl;
  final RpcWebSocketServer _rpcServer;

  Uri get url =>
      Uri.parse('ws://${_httpServer.address.host}:${_httpServer.port}');

  static Future<_Harness> start() async {
    final connCtl = StreamController<WebSocketChannel>();
    final httpServer = await HttpServer.bind('127.0.0.1', 0);
    httpServer.transform(WebSocketTransformer()).listen((ws) {
      if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
    });

    final rpcServer = RpcWebSocketServer.createWithContracts(
      connections: connCtl.stream,
      contracts: [_ContractResponder()..setup()],
    );
    await rpcServer.start();

    return _Harness(httpServer, connCtl, rpcServer);
  }

  Future<void> stop() async {
    await _rpcServer.stop();
    await _connCtl.close();
    await _httpServer.close(force: true);
  }
}

void main() {
  group('Typed RPC contracts over real WebSocket transport', () {
    late _Harness harness;
    late RpcWebSocketCallerTransport transport;
    late RpcCallerEndpoint caller;

    setUp(() async {
      harness = await _Harness.start();
      transport = await RpcWebSocketCallerTransport.connect(harness.url);
      caller = RpcCallerEndpoint(transport: transport);
    });

    tearDown(() async {
      await caller.close();
      await harness.stop();
    });

    test('unary request/response round-trips correctly', () async {
      final response = await caller
          .unaryRequest<EchoRequest, EchoResponse>(
            serviceName: serviceName,
            methodName: 'Unary',
            request: const EchoRequest('hello', count: 7),
            requestCodec: _reqCodec,
            responseCodec: _resCodec,
          )
          .timeout(const Duration(seconds: 5));

      expect(response.text, equals('reply:hello'));
      expect(response.index, equals(7));
    });

    test('server stream delivers all messages in order', () async {
      final responses = await caller
          .serverStream<EchoRequest, EchoResponse>(
            serviceName: serviceName,
            methodName: 'ServerStream',
            request: const EchoRequest('item', count: 10),
            requestCodec: _reqCodec,
            responseCodec: _resCodec,
          )
          .timeout(const Duration(seconds: 5))
          .toList();

      expect(responses.length, equals(10));
      for (var i = 0; i < responses.length; i++) {
        expect(responses[i].text, equals('item'));
        expect(
          responses[i].index,
          equals(i),
          reason: 'server-stream responses must keep order',
        );
      }
    });

    test('client stream aggregates uploaded messages', () async {
      final call = caller.clientStream<EchoRequest, EchoResponse>(
        serviceName: serviceName,
        methodName: 'ClientStream',
        requestCodec: _reqCodec,
        responseCodec: _resCodec,
      );

      final requests = Stream<EchoRequest>.fromIterable(const [
        EchoRequest('a'),
        EchoRequest('b'),
        EchoRequest('c'),
      ]);

      final response = await call(requests).timeout(const Duration(seconds: 5));

      expect(response.text, equals('a,b,c'));
      expect(response.index, equals(3));
    });

    test('bidirectional stream echoes each request in order', () async {
      final controller = StreamController<EchoRequest>();

      final responseStream = caller
          .bidirectionalStream<EchoRequest, EchoResponse>(
            serviceName: serviceName,
            methodName: 'BidiStream',
            requests: controller.stream,
            requestCodec: _reqCodec,
            responseCodec: _resCodec,
          );

      final received = <EchoResponse>[];
      final done = Completer<void>();
      final sub = responseStream.listen(
        received.add,
        onDone: done.complete,
        onError: (Object e) => done.completeError(e),
      );

      for (final t in ['one', 'two', 'three']) {
        controller.add(EchoRequest(t));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await controller.close();

      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      expect(
        received.map((r) => r.text).toList(),
        equals(['echo:one', 'echo:two', 'echo:three']),
      );
      expect(received.map((r) => r.index).toList(), equals([0, 1, 2]));
    });

    test('handler exception surfaces as typed RpcStatusException', () async {
      await expectLater(
        caller
            .unaryRequest<EchoRequest, EchoResponse>(
              serviceName: serviceName,
              methodName: 'Unary',
              request: const EchoRequest('BOOM'),
              requestCodec: _reqCodec,
              responseCodec: _resCodec,
            )
            .timeout(const Duration(seconds: 5)),
        throwsA(
          isA<RpcStatusException>()
              .having(
                (e) => e.statusCode,
                'statusCode',
                RpcStatus.invalidArgument,
              )
              .having((e) => e.message, 'message', contains('BOOM')),
        ),
      );
    });

    test(
      'cancelling a server stream mid-flight tears down without hang',
      () async {
        final stream = caller.serverStream<EchoRequest, EchoResponse>(
          serviceName: serviceName,
          methodName: 'InfiniteStream',
          request: const EchoRequest('forever'),
          requestCodec: _reqCodec,
          responseCodec: _resCodec,
        );

        final received = <EchoResponse>[];
        final gotSome = Completer<void>();
        final sub = stream.listen((r) {
          received.add(r);
          if (received.length >= 3 && !gotSome.isCompleted) gotSome.complete();
        });

        await gotSome.future.timeout(const Duration(seconds: 5));

        // Cancel must complete promptly (mirrors the core serverStream cancel
        // fix: cancel must not deadlock on the inner async* chain).
        await sub.cancel().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('server-stream cancel hung'),
        );

        // Transport stays usable after cancelling one call.
        final after = await caller
            .unaryRequest<EchoRequest, EchoResponse>(
              serviceName: serviceName,
              methodName: 'Unary',
              request: const EchoRequest('post-cancel'),
              requestCodec: _reqCodec,
              responseCodec: _resCodec,
            )
            .timeout(const Duration(seconds: 5));
        expect(after.text, equals('reply:post-cancel'));
      },
    );

    test('concurrent unary calls do not cross wires', () async {
      final futures = <Future<EchoResponse>>[];
      for (var i = 0; i < 25; i++) {
        futures.add(
          caller.unaryRequest<EchoRequest, EchoResponse>(
            serviceName: serviceName,
            methodName: 'Unary',
            request: EchoRequest('req$i', count: i),
            requestCodec: _reqCodec,
            responseCodec: _resCodec,
          ),
        );
      }

      final results = await Future.wait(
        futures,
      ).timeout(const Duration(seconds: 10));

      for (var i = 0; i < results.length; i++) {
        expect(
          results[i].text,
          equals('reply:req$i'),
          reason: 'response must match its own request',
        );
        expect(results[i].index, equals(i));
      }
    });

    test('concurrent server streams stay isolated', () async {
      Future<List<int>> run(String tag, int count) async {
        final responses = await caller
            .serverStream<EchoRequest, EchoResponse>(
              serviceName: serviceName,
              methodName: 'ServerStream',
              request: EchoRequest(tag, count: count),
              requestCodec: _reqCodec,
              responseCodec: _resCodec,
            )
            .timeout(const Duration(seconds: 5))
            .toList();
        for (final r in responses) {
          expect(
            r.text,
            equals(tag),
            reason: 'every response must belong to its own call',
          );
        }
        return responses.map((r) => r.index).toList();
      }

      final results = await Future.wait([
        run('A', 5),
        run('B', 8),
        run('C', 3),
      ]).timeout(const Duration(seconds: 10));

      expect(results[0], equals([0, 1, 2, 3, 4]));
      expect(results[1], equals([0, 1, 2, 3, 4, 5, 6, 7]));
      expect(results[2], equals([0, 1, 2]));
    });

    test('high-volume server stream arrives complete and ordered', () async {
      const total = 250;
      final responses = await caller
          .serverStream<EchoRequest, EchoResponse>(
            serviceName: serviceName,
            methodName: 'ServerStream',
            request: const EchoRequest('bulk', count: total),
            requestCodec: _reqCodec,
            responseCodec: _resCodec,
          )
          .timeout(const Duration(seconds: 15))
          .toList();

      expect(responses.length, equals(total));
      for (var i = 0; i < total; i++) {
        expect(responses[i].index, equals(i));
      }
    });
  });
}
