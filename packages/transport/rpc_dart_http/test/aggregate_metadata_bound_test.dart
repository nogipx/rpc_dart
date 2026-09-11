// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `maxMetadataBytes` bounds one inbound metadata block. It is NOT implied by
// `maxHeaders` and `maxHeaderValueBytes` — their defaults together allow
// 128 x 8 KiB = 1 MiB against a 64 KiB bound.
//
// The frame channel enforces it for websocket and wasm, http2's header-block
// guard for both of its halves, and this transport enforced nothing: measured,
// **960 000 bytes of headers came back 200 OK**, every individual header legal.
// The policy comment three lines above the field says why that is worse than
// having no field — "setting one bought a belief and no behaviour, and an
// operator hardening a deployment stops looking once the knob is set".
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
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

/// One raw HTTP/1.1 POST carrying [count] padding headers of [size] bytes, and
/// the status line that came back.
///
/// Raw rather than through the caller transport: the point is what an untrusted
/// PEER can put on the wire, and our own caller would not build this.
Future<String> post(int port, {required int count, required int size}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final answered = Completer<String>();
  void settle(String how) {
    if (!answered.isCompleted) answered.complete(how);
  }

  socket.listen(
    (bytes) => settle(String.fromCharCodes(bytes).split('\r\n').first),
    onError: (Object e) => settle('socket error: $e'),
    onDone: () => settle('closed with no reply'),
  );

  final buf = StringBuffer()
    ..write('POST /Svc/echo HTTP/1.1\r\n')
    ..write('host: 127.0.0.1\r\n')
    ..write('content-type: application/grpc+proto\r\n')
    ..write('te: trailers\r\n');
  for (var i = 0; i < count; i++) {
    buf.write('x-pad$i: ${"a" * size}\r\n');
  }
  buf.write('content-length: 5\r\n\r\n');

  socket.write(buf.toString());
  socket.add(const <int>[0, 0, 0, 0, 0]);
  await socket.flush();

  final reply = await answered.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => 'TIMEOUT',
  );
  socket.destroy();
  return reply;
}

void main() {
  late RpcHttpServer server;
  late int port;

  Future<void> serve(RpcSecurityPolicy policy) async {
    server = RpcHttpServer(
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
    port = server.actualPort!;
    addTearDown(server.stop);
  }

  test('a metadata block over the aggregate bound is refused', () async {
    await serve(const RpcSecurityPolicy(maxMetadataBytes: 64 * 1024));

    // 120 headers of 8000 bytes: inside maxHeaders (128) and inside
    // maxHeaderValueBytes (8192) individually, 960 000 bytes together.
    expect(
      await post(port, count: 120, size: 8000),
      contains('400'),
      reason: '960 000 bytes of headers against a 64 KiB bound',
    );

    // Just over, so the refusal is the BOUND and not the extremity.
    expect(await post(port, count: 100, size: 1000), contains('400'));
  });

  test('GUARD: an ordinary metadata block still passes', () async {
    await serve(const RpcSecurityPolicy(maxMetadataBytes: 64 * 1024));
    expect(
      await post(port, count: 4, size: 100),
      contains('200'),
      reason: 'the bound must refuse only what it names',
    );
  });

  test('GUARD: the per-header rules still apply on their own', () async {
    // The aggregate check runs FIRST, so it could shadow the existing
    // per-header refusal. A block that is small in total and still illegal has
    // to keep being refused for its own reason.
    await serve(const RpcSecurityPolicy(maxHeaders: 8));
    expect(await post(port, count: 40, size: 10), contains('400'));
  });
}
