// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A REFUSED request was the cheaper attack than an accepted one.
//
// `_reject` drains the request body before answering, and its doc comment said
// wall-clock was bounded by `bodyReadTimeout`. That timeout was applied around
// `readBody()` and nowhere else, so the drain ran with no deadline -- and a
// refusal happens before the stream is registered, so `pendingRequests` never
// counted it either. Sixteen sockets promising a body and sending five bytes,
// same server, `bodyReadTimeout: 500ms`, one header different:
//
//   content-type: application/grpc  ->  16 of 16 answered 408 within 3s
//   content-type: text/plain        ->   0 of 16 answered, all 16 draining
//
// An over-budget refusal now costs the peer its connection instead of costing
// the server a read loop with no end. Delivering the status was already
// best-effort: dart:io tears down a connection whose body was not consumed.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _sockets = 8;
const Duration _bodyReadTimeout = Duration(milliseconds: 500);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

Future<int> _serve() async {
  final transport = RpcHttpResponderTransport(
    bodyReadTimeout: _bodyReadTimeout,
  );
  final endpoint = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_Svc())
    ..start();
  final httpServer = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
  addTearDown(() async {
    await endpoint.close();
    await httpServer.close(force: true);
  });
  return httpServer.port;
}

/// Opens a request that promises a body and sends almost none, holding the
/// connection. Completes when the server answers OR hangs up; never on its own.
Future<String> _slowBody(int port, String contentType) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final settled = Completer<String>();
  void finish(String how) {
    if (!settled.isCompleted) settled.complete(how);
  }

  socket.listen(
    (bytes) => finish(String.fromCharCodes(bytes).split('\r\n').first),
    onDone: () => finish('closed'),
    onError: (_) => finish('closed'),
  );
  socket.write(
    'POST /Svc/echo HTTP/1.1\r\n'
    'host: 127.0.0.1:$port\r\n'
    'content-type: $contentType\r\n'
    'content-length: 100000\r\n'
    '\r\n',
  );
  socket.add(const <int>[0, 0, 0, 0, 4]);
  await socket.flush();
  addTearDown(socket.destroy);
  return settled.future;
}

/// A complete, well-formed request with the wrong content type.
Future<String> _fastBadContentType(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final settled = Completer<String>();
  socket.listen(
    (bytes) {
      if (!settled.isCompleted) {
        settled.complete(String.fromCharCodes(bytes).split('\r\n').first);
      }
    },
    onDone: () {
      if (!settled.isCompleted) settled.complete('closed');
    },
    onError: (_) {
      if (!settled.isCompleted) settled.complete('closed');
    },
  );
  socket.write(
    'POST /Svc/echo HTTP/1.1\r\n'
    'host: 127.0.0.1:$port\r\n'
    'content-type: text/plain\r\n'
    'content-length: 5\r\n'
    '\r\n'
    'hello',
  );
  await socket.flush();
  addTearDown(socket.destroy);
  return settled.future;
}

Future<List<String>> _settleAll(List<Future<String>> attacks) => Future.wait(
  attacks.map(
    (f) => f.timeout(_bodyReadTimeout * 6, onTimeout: () => 'STILL DRAINING'),
  ),
);

void main() {
  test(
    'a refused request is bounded by bodyReadTimeout too',
    () async {
      // WITNESS. Pre-fix all 8 read STILL DRAINING; the drain had no deadline.
      final port = await _serve();

      final settled = await _settleAll([
        for (var i = 0; i < _sockets; i++) _slowBody(port, 'text/plain'),
      ]);

      expect(
        settled.where((s) => s == 'STILL DRAINING'),
        isEmpty,
        reason: 'every refused slow body must be let go inside the budget',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: the accepted path is still bounded, and answers 408',
    () async {
      // The path that always worked. Without it the witness would pass on a
      // server that had simply stopped reading bodies at all.
      final port = await _serve();

      final settled = await _settleAll([
        for (var i = 0; i < _sockets; i++) _slowBody(port, 'application/grpc'),
      ]);

      expect(settled.where((s) => s == 'STILL DRAINING'), isEmpty);
      expect(settled, everyElement(contains('408')));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a refusal inside the budget still gets its status',
    () async {
      // The fix must bound the SLOW refusal without turning an ordinary one into
      // a dropped connection.
      final port = await _serve();

      expect(
        await _fastBadContentType(port).timeout(const Duration(seconds: 10)),
        contains('415'),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
