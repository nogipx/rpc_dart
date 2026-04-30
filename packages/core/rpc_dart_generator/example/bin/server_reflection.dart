// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Integration test: codegen contract + gRPC Server Reflection (Tier 2).
//
// Run:
//   fvm dart run bin/server_reflection.dart
//
// Test:
//   grpcurl -plaintext localhost:50051 list
//   grpcurl -plaintext localhost:50051 describe Calculator

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

import 'package:rpc_dart_generator_consumer/calculator_contract.dart';

class CalculatorResponder extends CalculatorContractResponder {
  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) async {
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }

  @override
  Stream<SumResponse> numbers(
    SumRequest request, {
    RpcContext? context,
  }) async* {
    for (final v in request.values) {
      yield SumResponse(result: v);
    }
  }
}

void main() async {
  final registry = RpcReflectionRegistry()
    ..addFileDescriptor(CalculatorContractNames.grpcDescriptor);

  final server = RpcHttp2Server(
    host: '0.0.0.0',
    port: 50051,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(CalculatorResponder());
      registry.attachTo(endpoint);
      endpoint.start();
    },
  );

  await server.start();
  stderr.writeln('Server on :50051');
  stderr.writeln('  grpcurl -plaintext localhost:50051 list');
  stderr.writeln('  grpcurl -plaintext localhost:50051 describe Calculator');

  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  ProcessSignal.sigterm.watch().listen((_) => done.complete());
  await done.future;

  await server.stop();
}
