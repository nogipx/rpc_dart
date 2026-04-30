// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

// Example: gRPC Server Reflection with protobuf-typed service.
//
// Uses RpcBinaryCodec so grpcurl can actually call methods.
// Reflection descriptor is built from generated .pbjson.dart bytes (Tier 1).
//
// Run:
//   fvm dart run example/server_protobuf.dart
//
// Test with grpcurl:
//   grpcurl -plaintext localhost:50051 list
//   grpcurl -plaintext localhost:50051 describe echo.v1.EchoService
//   grpcurl -plaintext -d '{"message":"hello","count":2}' localhost:50051 echo.v1.EchoService/Echo
//   grpcurl -plaintext -d '{"message":"hi","count":3}' localhost:50051 echo.v1.EchoService/EchoStream

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

import 'gen/echo.pb.dart';
import 'gen/echo.pbjson.dart';

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------

final _reqCodec = RpcBinaryCodec<EchoRequest>(
  toBytes: (r) => r.writeToBuffer(),
  fromBytes: EchoRequest.fromBuffer,
);

final _resCodec = RpcBinaryCodec<EchoResponse>(
  toBytes: (r) => r.writeToBuffer(),
  fromBytes: EchoResponse.fromBuffer,
);

// ---------------------------------------------------------------------------
// Contract
// ---------------------------------------------------------------------------

class EchoResponderContract extends RpcResponderContract {
  EchoResponderContract() : super('echo.v1.EchoService') {
    addUnaryMethod<EchoRequest, EchoResponse>(
      methodName: 'Echo',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: _echo,
    );
    addServerStreamMethod<EchoRequest, EchoResponse>(
      methodName: 'EchoStream',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: _echoStream,
    );
  }

  Future<EchoResponse> _echo(EchoRequest req, {RpcContext? context}) async =>
      EchoResponse(message: 'echo: ${req.message}', index: 0);

  Stream<EchoResponse> _echoStream(
    EchoRequest req, {
    RpcContext? context,
  }) async* {
    final count = req.count > 0 ? req.count : 3;
    for (var i = 0; i < count; i++) {
      yield EchoResponse(message: 'echo: ${req.message} [$i]', index: i);
    }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() async {
  final registry = RpcReflectionRegistry()
    ..addFromPbjson(
      name: 'echo.proto',
      package: 'echo.v1',
      messages: [echoRequestDescriptor, echoResponseDescriptor],
      services: [echoServiceDescriptor],
    );

  final server = RpcHttp2Server(
    host: '0.0.0.0',
    port: 50051,
    onEndpointCreated: (endpoint) {
      registry.attachTo(endpoint);
      endpoint.registerServiceContract(EchoResponderContract());
      endpoint.start();
    },
  );

  await server.start();
  stderr.writeln('Server listening on :50051 (protobuf codec)');
  stderr.writeln('Try:');
  stderr.writeln('  grpcurl -plaintext localhost:50051 list');
  stderr.writeln(
    '  grpcurl -plaintext -d \'{"message":"hello","count":2}\' localhost:50051 echo.v1.EchoService/Echo',
  );

  final done = Completer<void>();
  ProcessSignal.sigterm.watch().listen((_) => done.complete());
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;

  await server.stop();
}
