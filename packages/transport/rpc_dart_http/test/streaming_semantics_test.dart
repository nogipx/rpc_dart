// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller transport documented streaming methods as ones that "will fail".
// They do not fail, and the difference is what an application trips over.
//
// Measured on this transport:
//
//   finite server stream, 3 items yielded 400ms apart
//     -> arrival times [1290, 1290, 1290]ms
//        nothing until the handler completed, then all three at once
//
//   unbounded server stream, client takes 2
//     -> no items in 5s; handler had produced 225 yields and was still
//        running after the caller gave up
//
// So the real behaviour is "silently degrades to buffering, and an unbounded
// stream is a hang", not "fails". These tests pin that, and pin the mitigation
// the docs now recommend: a deadline bounds the hang.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Set while the paced handler is still running, so a test can prove delivery
/// happened only after it finished.
bool pacedRunning = false;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => 'u:${r.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'paced',
      handler: (r, {RpcContext? context}) async* {
        pacedRunning = true;
        try {
          for (var i = 0; i < 3; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            yield 'p$i'.rpc;
          }
        } finally {
          pacedRunning = false;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'endless',
      handler: (r, {RpcContext? context}) async* {
        while (true) {
          yield 'e'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late HttpServer server;
  late RpcHttpResponderTransport serverTransport;
  late RpcResponderEndpoint responder;
  late RpcCallerEndpoint caller;

  setUp(() async {
    pacedRunning = false;
    serverTransport = RpcHttpResponderTransport();
    server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
    responder = RpcResponderEndpoint(transport: serverTransport);
    responder.registerServiceContract(_Svc());
    responder.start();
    caller = RpcCallerEndpoint(
      transport: RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      ),
    );
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await server.close(force: true);
  });

  group('streaming over HTTP/1.1', () {
    // CHARACTERIZATION: the docs said this would FAIL. It succeeds.
    test('a finite server stream succeeds rather than failing', () async {
      final got = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'paced',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(
        got.map((e) => e.value),
        ['p0', 'p1', 'p2'],
        reason: 'a finite server stream round-trips here, buffered',
      );
    });

    // CHARACTERIZATION: buffered, not incremental. Nothing arrives until the
    // handler has finished, which is what makes an unbounded stream a hang.
    test('nothing is delivered until the handler completes', () async {
      final stream = caller.serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'paced',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );

      final first = await stream.first.timeout(const Duration(seconds: 10));

      expect(first.value, 'p0');
      expect(
        pacedRunning,
        isFalse,
        reason:
            'the first item arrived while the handler was still running, so '
            'delivery is incremental after all and the docs should say so',
      );
    });

    // The mitigation the docs now recommend. Without a deadline this call
    // never returns, so this also pins that the advice is real.
    test('a deadline bounds an otherwise unbounded stream', () async {
      final sw = Stopwatch()..start();
      Object? error;
      try {
        await caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'endless',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: RpcContext.withTimeout(
                const Duration(milliseconds: 400),
              ),
            )
            .toList()
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        error = e;
      }
      sw.stop();

      expect(
        error,
        isNotNull,
        reason:
            'an unbounded stream returned normally, which cannot happen '
            'when the response only starts after the handler finishes',
      );
      expect(
        error,
        isNot(isA<TimeoutException>()),
        reason:
            'the call ran past the 8s test guard rather than being ended by '
            'its own 400ms deadline: the deadline does not bound it',
      );
    });
  });

  group('unary is unaffected', () {
    // GUARD: the shape this transport is actually for.
    test('a unary call round-trips', () async {
      final res = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(res.value, 'u:hi');
    });
  });
}
