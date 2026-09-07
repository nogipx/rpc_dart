// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller READ the error body and threw it away.
//
// Every non-200 became `grpc-message: "HTTP <code> from <path>"`, which does not
// say which limit was hit or even that a limit was involved -- while this
// transport's own rejections had a reason to give:
//
//   413  Request body exceeds limit of N bytes
//   400  Metadata violation: ...
//
// The body was already being drained (it has to be, or dart:io tears the
// connection down), so nothing was saved by discarding it.
//
// It is NOT trusted, though: a non-200 can come from a proxy or a captive
// portal, so what is repeated is a bounded, single-line, printable prefix.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
    );
  }
}

Future<RpcCallerEndpoint> _serve(RpcSecurityPolicy policy) async {
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: policy,
    onEndpointCreated: (e) {
      e.registerServiceContract(_Svc());
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();

  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.actualPort}',
      // Generous, so the ceiling under test is the SERVER's.
      policy: const RpcSecurityPolicy(maxMessageLengthBytes: 32 * 1024 * 1024),
    ),
  );
  addTearDown(() async {
    await caller.close();
    await server.stop();
  });
  return caller;
}

Future<Object?> _errorOf(Future<Object?> call) async {
  try {
    await call;
    return null;
  } catch (e) {
    return e;
  }
}

Future<RpcString> _echo(
  RpcCallerEndpoint caller,
  String value, {
  RpcContext? context,
}) => caller.unaryRequest<RpcString, RpcString>(
  serviceName: 'Svc',
  methodName: 'echo',
  request: value.rpc,
  requestCodec: _codec,
  responseCodec: _codec,
  context: context,
);

void main() {
  test(
    'a 413 carries WHICH limit was hit',
    () async {
      // WITNESS. Pre-fix: "HTTP 413 from /Svc/echo" and nothing else.
      final caller = await _serve(
        const RpcSecurityPolicy(maxMessageLengthBytes: 4096),
      );

      final error = await _errorOf(
        _echo(caller, 'x' * (256 * 1024)).timeout(const Duration(seconds: 30)),
      );

      expect(error, isA<RpcStatusException>());
      expect(
        (error! as RpcStatusException).statusCode,
        RpcStatus.resourceExhausted,
      );
      expect(
        (error as RpcStatusException).message,
        allOf(contains('413'), contains('Request body exceeds limit')),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a metadata rejection says it was the metadata',
    () async {
      // WITNESS. Pre-fix: "HTTP 400 from /Svc/echo", which does not distinguish a
      // header violation from a malformed path or an unreadable body.
      final caller = await _serve(const RpcSecurityPolicy(maxHeaders: 4));

      final context = RpcContext.withHeaders({
        for (var i = 0; i < 50; i++) 'x-h$i': 'v',
      });
      final error = await _errorOf(
        _echo(
          caller,
          'hi',
          context: context,
        ).timeout(const Duration(seconds: 30)),
      );

      expect(error, isA<RpcStatusException>());
      expect(
        (error! as RpcStatusException).message,
        allOf(contains('400'), contains('Metadata violation')),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a foreign error body is bounded and single-line',
    () async {
      // A non-200 does not have to come from this library. A proxy answering with
      // an HTML page must not paste the page into a status message.
      final noisy = 'x' * 5000;
      final http = await shelf_io.serve(
        (shelf.Request _) =>
            shelf.Response(502, body: '<html>\n\tbad gateway\n\n$noisy</html>'),
        '127.0.0.1',
        0,
      );
      addTearDown(() => http.close(force: true));

      final caller = RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${http.port}',
        ),
      );
      addTearDown(caller.close);

      final error = await _errorOf(
        _echo(caller, 'hi').timeout(const Duration(seconds: 30)),
      );

      expect(error, isA<RpcStatusException>());
      final message = (error! as RpcStatusException).message;
      expect(message, contains('502'));
      expect(message, contains('bad gateway'));
      expect(message.contains('\n'), isFalse, reason: 'collapsed to one line');
      expect(
        message.length,
        lessThan(400),
        reason: 'a whole page has no place in a status message',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an empty error body still gives the old message',
    () async {
      // Nothing to repeat must not produce a trailing separator or an empty tail.
      final http = await shelf_io.serve(
        (shelf.Request _) => shelf.Response(503),
        '127.0.0.1',
        0,
      );
      addTearDown(() => http.close(force: true));

      final caller = RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${http.port}',
        ),
      );
      addTearDown(caller.close);

      final error = await _errorOf(
        _echo(caller, 'hi').timeout(const Duration(seconds: 30)),
      );

      expect(error, isA<RpcStatusException>());
      expect((error! as RpcStatusException).message, endsWith('/Svc/echo'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a successful call is untouched',
    () async {
      final caller = await _serve(const RpcSecurityPolicy());
      final response = await _echo(
        caller,
        'hi',
      ).timeout(const Duration(seconds: 30));
      expect(response.value, 'ok');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
