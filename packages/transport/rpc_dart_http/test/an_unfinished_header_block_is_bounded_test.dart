// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request whose header block never ends is bounded in bytes and in time.
//
// dart:io holds an unfinished header block below every rpc_dart limit, up to
// about 3 MiB per connection, for as long as the client keeps it open, and
// `HttpServer.idleTimeout` does not cover it. RpcHttpServer bounds the block
// by its security policy (method path, metadata, header count) and by
// `headerTimeout`, and can cap the connections it keeps open.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

Future<RpcHttpServer> _serve({
  Duration? headerTimeout = const Duration(seconds: 60),
  int? maxConnections,
}) async {
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (_) {},
    headerTimeout: headerTimeout,
    maxConnections: maxConnections,
  );
  await server.start();
  await server.afterModulesStart();
  addTearDown(server.stop);
  return server;
}

/// Opens a connection and sends a request line plus [kib] KiB of header
/// lines, never ending the block. Completes with true once the server closes
/// it, false if it is still open after [within].
Future<bool> _closedWithin(
  RpcHttpServer server, {
  required int kib,
  required Duration within,
}) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.actualPort!,
  );
  addTearDown(socket.destroy);
  final closed = Completer<bool>();
  socket.listen(
    (_) {},
    onDone: () => closed.isCompleted ? null : closed.complete(true),
    onError: (Object _) => closed.isCompleted ? null : closed.complete(true),
  );
  socket.add('POST /Svc/m HTTP/1.1\r\nhost: x\r\n'.codeUnits);
  final line = 'x-pad: ${'a' * 1000}\r\n'.codeUnits;
  for (var i = 0; i < kib; i++) {
    socket.add(line);
  }
  await socket.flush().catchError((Object _) {});
  return closed.future.timeout(within, onTimeout: () => false);
}

void main() {
  test('WITNESS: a header block over the policy is closed at once', () async {
    final server = await _serve(headerTimeout: null);
    expect(
      await _closedWithin(server, kib: 900, within: const Duration(seconds: 2)),
      isTrue,
      reason: 'the server kept a 900 KiB unfinished header block',
    );
  });

  test('GUARD: a header block within the policy is not cut', () async {
    final server = await _serve(headerTimeout: null);
    expect(
      await _closedWithin(server, kib: 60, within: const Duration(seconds: 1)),
      isFalse,
    );
  });

  test(
    'WITNESS: an unfinished header block is closed after headerTimeout',
    () async {
      final server = await _serve(
        headerTimeout: const Duration(milliseconds: 300),
      );
      expect(
        await _closedWithin(server, kib: 1, within: const Duration(seconds: 2)),
        isTrue,
        reason: 'the server kept an unfinished header block past headerTimeout',
      );
    },
  );

  test('WITNESS: a connection past maxConnections is closed', () async {
    final server = await _serve(headerTimeout: null, maxConnections: 2);
    final held = [
      await _closedWithin(server, kib: 1, within: Duration.zero),
      await _closedWithin(server, kib: 1, within: Duration.zero),
    ];
    expect(held, [false, false]);
    expect(
      await _closedWithin(server, kib: 1, within: const Duration(seconds: 2)),
      isTrue,
      reason: 'a third connection was kept with maxConnections: 2',
    );
  });

  // The deadline runs from a later request's first byte, not from the
  // previous answer: a kept-alive connection idles under dart:io's own
  // idleTimeout. Raw, because HttpClient silently redials a pooled connection
  // the server closed, which hides the difference.
  test('GUARD: a kept-alive connection may idle past headerTimeout', () async {
    final server = await _serve(
      headerTimeout: const Duration(milliseconds: 300),
    );
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.actualPort!,
    );
    addTearDown(socket.destroy);
    final answered = Completer<void>();
    var closed = false;
    socket.listen(
      (_) => answered.isCompleted ? null : answered.complete(),
      onDone: () => closed = true,
      onError: (Object _) => closed = true,
    );
    socket.add(
      'POST /Svc/m HTTP/1.1\r\nhost: x\r\ncontent-type: application/grpc\r\n'
              'content-length: 0\r\n\r\n'
          .codeUnits,
    );
    await answered.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(closed, isFalse, reason: 'an idle kept-alive connection was cut');
  });
}
