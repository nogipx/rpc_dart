// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server and a client in one process, over a Unix socket in a temp dir.

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class Greeter extends RpcResponderContract {
  Greeter() : super('Greeter');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: (name, {RpcContext? context}) async =>
          'Hello, ${name.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('rpc');
  final address = RpcSocketAddress.unix('${dir.path}/rpc.sock');

  final server = RpcSocketServer.createWithContracts(
    address: address,
    contracts: [Greeter()],
  );
  await server.start();

  final caller = RpcCallerEndpoint(transport: await connectRpcSocket(address));
  final reply = await caller.unary<RpcString, RpcString>(
    serviceName: 'Greeter',
    methodName: 'hello',
    request: 'socket'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  stdout.writeln(reply.value);

  await caller.close();
  await server.stop();
  dir.deleteSync(recursive: true);
}
