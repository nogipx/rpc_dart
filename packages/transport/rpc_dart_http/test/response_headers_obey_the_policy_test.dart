// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Core validates peer metadata in `_validateInbound`, but this transport is not an
// `RpcChannelTransport` -- it is its own `IRpcTransport` -- so that check never ran on
// it and the response headers went up with no count, size or character check.
// Measured against a server answering with 1000 extra headers:
//
//     headers delivered  1007        on a maxHeaders of 128
//     grpc-status        9
//
// Reduced, NOT refused, because refusing destroys the server's status -- round 567 had
// to undo exactly that on http2, and `RpcSecurityPolicy.statusOnly` is now the one home
// for the rule.
//
// WHERE THE STATUS LIVES MATTERS. This transport routes `grpc-status` and
// `grpc-message` into the TRAILER frame, so an offending INITIAL frame has no status to
// keep and must not invent one: a first attempt answered it with this side's
// INVALID_ARGUMENT, which reached the caller before the server's real 9 and won. That
// is what the second assertion below is for.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Answers one gRPC frame, a real `grpc-status: 9`, and [extraHeaders] of noise.
Future<HttpServer> _server({required int extraHeaders}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((request) async {
    await request.drain<void>();
    final r = request.response;
    r.statusCode = 200;
    r.headers.set('content-type', 'application/grpc+proto');
    for (var i = 0; i < extraHeaders; i++) {
      r.headers.add('x-shout-$i', 'v');
    }
    r.headers.set('grpc-status', '9');
    r.headers.set('grpc-message', 'the precondition failed');
    r.add(RpcMessageFrame.encode(_codec.serialize('ok'.rpc)));
    await r.close();
  }, onError: (Object _) {});
  return server;
}

/// One call, returning the total headers delivered and the first status seen.
Future<(int, String?)> _call({required int extraHeaders}) async {
  final server = await _server(extraHeaders: extraHeaders);
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await server.close(force: true);
  });

  var headerCount = 0;
  String? status;
  final done = Completer<void>();
  final id = transport.createStream();
  transport
      .getMessagesForStream(id)
      .listen(
        (m) {
          final md = m.metadata;
          if (md != null) {
            headerCount += md.headers.length;
            // FIRST status wins, which is the point: a manufactured one on the initial
            // frame would be seen here instead of the server's.
            status ??= md.getHeaderValue(RpcHeaders.grpcStatus);
          }
          if (m.isEndOfStream && !done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );

  await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'echo'));
  await transport.sendMessage(
    id,
    RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
    endStream: true,
  );
  await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});

  return (headerCount, status);
}

void main() {
  // WITNESS. Before: 1007 headers delivered.
  test('a response with more headers than the policy allows is reduced', () async {
    final (headers, status) = await _call(extraHeaders: 1000);

    expect(
      headers,
      lessThan(128),
      reason:
          'maxHeaders is 128 and this transport never checked it, so a server '
          'or a proxy could hand the application a thousand headers',
    );
    expect(
      status,
      '9',
      reason:
          'the SERVER\'s status must be the first one the caller sees; '
          'answering the offending initial frame with our own INVALID_ARGUMENT '
          'puts a manufactured status ahead of the real one',
    );
  });

  // CONTROL. A conforming response is untouched -- so the witness is about the
  // policy and not about this transport having stopped delivering metadata.
  test('CONTROL: a conforming response is delivered whole', () async {
    final (headers, status) = await _call(extraHeaders: 2);

    expect(headers, 9);
    expect(status, '9');
  });
}
