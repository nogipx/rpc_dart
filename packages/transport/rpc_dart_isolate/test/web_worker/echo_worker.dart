// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Worker-side program for the real Web Worker e2e test
// (`echo_worker_test.dart`).
//
// This file is SEPARATELY compiled to JS and loaded by
// `RpcIsolateTransport.spawn(workerUri: ...)` as a dedicated Web Worker. Its
// `main()` runs INSIDE the worker scope; it wires the worker transport via
// `runRpcIsolateManagerWorker` and registers an echo RPC responder.
//
// Build:
//   fvm dart compile js test/web_worker/echo_worker.dart \
//     -o test/web_worker/echo_worker.dart.js
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

void main() {
  runRpcIsolateManagerWorker(_echoServer);
}

void _echoServer(IRpcTransport transport, Map<String, dynamic> params) {
  final responder = RpcResponderEndpoint(transport: transport);
  responder.registerServiceContract(_EchoContract());
  responder.start();
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('EchoService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: _echo,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'EchoStream',
      handler: _echoStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _echo(RpcString request, {RpcContext? context}) async {
    return 'echo:${request.value}'.rpc;
  }

  Stream<RpcString> _echoStream(
    RpcString request, {
    RpcContext? context,
  }) async* {
    for (var i = 0; i < 3; i++) {
      yield 'stream:${request.value}:$i'.rpc;
    }
  }
}
