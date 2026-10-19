// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The frame channel's preface is how each side learns that the other is
// rpc_dart. A client is not ready until the server has answered it, and a
// server builds no endpoint until the client's has arrived.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

/// A fake server at a fresh Unix path that runs [onConnect] on every socket.
Future<RpcSocketAddress> _fake(void Function(Socket socket) onConnect) async {
  final path = tempSocketPath();
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final held = <Socket>[];
  addTearDown(() async {
    for (final s in held) {
      s.destroy();
    }
    await server.close();
  });
  server.listen((s) {
    held.add(s);
    s.listen((_) {}, onError: (Object _) {});
    s.done.catchError((Object _) => s).ignore();
    onConnect(s);
  });
  return RpcSocketAddress.unix(path);
}

void main() {
  test('WITNESS: a server that never speaks is never ready', () async {
    final address = await _fake((_) {});
    final transport = await connectRpcSocket(
      address,
      connectTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(transport.close);
    expect(
      await statusOf(() => transport.ready),
      'status ${RpcStatus.unavailable}',
    );
    expect((await transport.health()).isHealthy, isFalse);
  });

  test('WITNESS: a server speaking something else is UNKNOWN, '
      'to ready and to a call', () async {
    final address = await _fake((s) => s.add('HTTP/1.1 400 Bad\r\n'.codeUnits));
    final transport = await connectRpcSocket(address);
    final caller = EchoCaller(RpcCallerEndpoint(transport: transport));
    addTearDown(caller.endpoint.close);
    final call = statusOf(() => caller.unary('anyone?'));
    expect(
      await statusOf(() => transport.ready),
      'status ${RpcStatus.unknown}',
    );
    expect(await call, 'status ${RpcStatus.unknown}');
  });

  test('WITNESS: another protocol version is FAILED_PRECONDITION', () async {
    final address = await _fake(
      (s) => s.add([
        ...RpcChannelFrame.preface.sublist(0, RpcChannelFrame.prefaceSize - 1),
        RpcChannelFrame.protocolVersion + 1,
      ]),
    );
    final transport = await connectRpcSocket(address);
    addTearDown(transport.close);
    expect(
      await statusOf(() => transport.ready),
      'status ${RpcStatus.failedPrecondition}',
    );
  });

  test('WITNESS: a preface split across reads is still a preface', () async {
    final address = await _fake((s) async {
      for (final b in RpcChannelFrame.preface) {
        s.add([b]);
        await s.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    final transport = await connectRpcSocket(address);
    addTearDown(transport.close);
    await transport.ready.timeout(callTimeout);
    expect((await transport.health()).isHealthy, isTrue);
  });

  test('WITNESS: a client that never sends its preface loses its slot, '
      'and a real client gets it', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    final server = RpcSocketServer(
      address: address,
      maxConnections: 1,
      prefaceTimeout: const Duration(milliseconds: 200),
      mode: RpcResponderMode((e) => e.registerServiceContract(EchoResponder())),
    );
    await server.start();
    addTearDown(server.stop);

    final silent = await Socket.connect(address.host, 0);
    addTearDown(silent.destroy);
    final hungUp = Completer<void>();
    silent.listen(
      (_) {},
      onError: (Object _) {},
      onDone: () => hungUp.isCompleted ? null : hungUp.complete(),
    );
    await hungUp.future.timeout(callTimeout);
    expect(server.endpoints, isEmpty);

    final caller = await dialEcho(address);
    expect(await caller.unary('mine now'), 'mine now');
  });

  test('GUARD: calls made before ready are answered', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    await serveEcho(address);
    final transport = await connectRpcSocket(address);
    final caller = EchoCaller(RpcCallerEndpoint(transport: transport));
    addTearDown(caller.endpoint.close);
    // No await on ready: the request goes out behind the preface.
    expect(await caller.unary('early'), 'early');
  });
}
