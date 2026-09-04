// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer RESET must reach the caller as a gRPC status, not as package:http2's
// StreamTransportException.
//
// RST_STREAM is how a real gRPC server aborts one call while the connection
// stays healthy: a server-side deadline, a server at capacity refusing the
// stream, a proxy dropping it. Measured against a raw package:http2 server
// that reset the stream, every shape came back the same way:
//
//   rst before response  : StreamTransportException ... (errorCode: 8)
//   rst after headers    : StreamTransportException ... (errorCode: 8)
//   rst mid server-stream: got [item-0, item-1], errors [StreamTransportException]
//
// Nothing above the transport can act on that. RpcRetryInterceptor, circuit
// breakers and failover all key off the gRPC status, so a REFUSED_STREAM from
// an overloaded server -- safe to retry, because the server never processed
// the request -- was as unclassifiable as a deliberate CANCEL. Same defect as
// the raw StateError on a drained connection (ff1f6337) and as non-200
// statuses collapsing to INTERNAL (e4756025).
//
// Only CANCEL is reachable end-to-end here: package:http2's `terminate()`
// takes no error code and always sends 8. The rest of the table, and the
// message parse it depends on, are pinned as unit tests below.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// How the server treats the next stream.
String _mode = 'ok';

void main() {
  group('end to end', () {
    late ServerSocket socket;
    late RpcHttp2CallerTransport transport;
    late RpcCallerEndpoint caller;

    setUp(() async {
      socket = await ServerSocket.bind('127.0.0.1', 0);
      socket.listen((client) {
        final conn = http2.ServerTransportConnection.viaSocket(client);
        conn.incomingStreams.listen((stream) {
          stream.incomingMessages.listen((_) {}, onError: (Object _) {});
          switch (_mode) {
            case 'rstImmediate':
              stream.terminate();
            case 'rstMidStream':
              stream.sendHeaders([
                http2.Header.ascii(':status', '200'),
                http2.Header.ascii('content-type', 'application/grpc+proto'),
              ]);
              for (var i = 0; i < 2; i++) {
                stream.sendData(
                  RpcMessageFrame.encode(
                    _codec.serialize('item-$i'.rpc),
                    compressed: false,
                  ),
                );
              }
              Timer(const Duration(milliseconds: 200), stream.terminate);
            default:
              stream.sendHeaders([
                http2.Header.ascii(':status', '200'),
                http2.Header.ascii('content-type', 'application/grpc+proto'),
              ]);
              stream.sendData(
                RpcMessageFrame.encode(
                  _codec.serialize('ok'.rpc),
                  compressed: false,
                ),
              );
              stream.sendHeaders([
                http2.Header.ascii('grpc-status', '0'),
              ], endStream: true);
          }
        }, onError: (Object _) {});
      }, onError: (Object _) {});

      transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: socket.port,
      );
      caller = RpcCallerEndpoint(transport: transport);
    });

    tearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await socket.close();
    });

    test('a reset unary call raises a gRPC status', () async {
      _mode = 'rstImmediate';
      Object? thrown;
      try {
        await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        thrown = e;
      }

      expect(
        thrown,
        isA<RpcStatusException>(),
        reason:
            'package:http2 raises StreamTransportException here, which no '
            'layer above the transport can classify',
      );
      // terminate() sends CANCEL(8) -> CANCELLED, and NOT a retryable status:
      // re-running a call the peer deliberately aborted would repeat side
      // effects it asked to stop.
      expect((thrown! as RpcStatusException).statusCode, RpcStatus.cancelled);
    });

    test('a reset server stream errors after its delivered items', () async {
      _mode = 'rstMidStream';
      final got = <String>[];
      final errors = <Object>[];
      var done = false;

      final sub = caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Stream',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (v) => got.add(v.value),
            onError: errors.add,
            onDone: () => done = true,
            cancelOnError: false,
          );
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(seconds: 3));

      expect(got, ['item-0', 'item-1'], reason: 'delivered items are kept');
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<RpcStatusException>(),
        reason:
            'a truncated stream must fail with a status the caller can act '
            'on, not with a transport exception',
      );
      expect(done, isTrue);
    });

    test('GUARD: the connection survives a reset stream', () async {
      _mode = 'rstImmediate';
      try {
        await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // expected
      }

      // RST_STREAM kills one stream, not the connection. If this regressed,
      // one aborted call would take every other call on the socket with it.
      _mode = 'ok';
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'ok');
      expect(transport.isClosed, isFalse);
      expect((await transport.health()).level, RpcHealthLevel.healthy);
    });
  });

  group('the mapping table', () {
    test('follows PROTOCOL-HTTP2, and the retry-relevant rows differ', () {
      // REFUSED_STREAM means the server never processed the request, so it is
      // safe to retry even a non-idempotent call -- and UNAVAILABLE is what
      // RpcRetryInterceptor retries.
      expect(grpcStatusFromHttp2ErrorCode(7), RpcStatus.unavailable);
      // CANCEL is a deliberate abort and must NOT be retried.
      expect(grpcStatusFromHttp2ErrorCode(8), RpcStatus.cancelled);
      expect(grpcStatusFromHttp2ErrorCode(11), RpcStatus.resourceExhausted);
      expect(grpcStatusFromHttp2ErrorCode(12), RpcStatus.permissionDenied);

      // Unknown codes fall to INTERNAL, which is both the spec default and the
      // safe answer: it is not retried. Guessing UNAVAILABLE here would retry
      // aborts that must not be.
      for (final code in [0, 1, 2, 3, 4, 5, 6, 9, 10, 99]) {
        expect(
          grpcStatusFromHttp2ErrorCode(code),
          RpcStatus.internal,
          reason: 'errorCode $code must not become retryable by accident',
        );
      }
    });

    test('GUARD: pins the package:http2 message this parse depends on', () {
      // package:http2 does not expose the error code as a field, so it is read
      // out of the exception text. There is exactly ONE construction site for
      // this exception in the package (stream_handler.dart). If that wording
      // ever changes, this fails loudly here instead of silently degrading
      // every reset to INTERNAL in production.
      final real = http2.StreamTransportException(
        'Stream was terminated by peer (errorCode: 7).',
      );
      expect(http2ErrorCodeFromMessage(real.message), 7);
      expect(
        grpcStatusFromHttp2ErrorCode(http2ErrorCodeFromMessage(real.message)!),
        RpcStatus.unavailable,
      );
    });

    test('an unreadable message degrades to INTERNAL, not to a guess', () {
      expect(http2ErrorCodeFromMessage('something else entirely'), isNull);
    });
  });
}
