// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

// Example: gRPC Server Reflection with rpc_dart
//
// Builds the reflection descriptor by hand with RpcFileDescriptorBuilder
// (field and method metadata) and serves it next to a CBOR service.
// Other ways to get descriptor bytes:
//   - protoc output (.pbjson.dart): RpcReflectionRegistry.addFromPbjson,
//     see example/server_protobuf.dart.
//   - rpc_dart_generator with @RpcService(grpcDescriptor: true):
//     registry.addFileDescriptor(<Base>Names.grpcDescriptor).
//
// DISCOVERY ONLY. This service is wired with `RpcCodec`, which is CBOR, so a
// descriptor makes it DESCRIBABLE, not callable by a protobuf client. Reflection
// and the wire format are independent: grpcurl reads the descriptor over
// reflection and then sends protobuf, which this codec cannot parse. The call
// fails with `Code: Internal`. For a service a foreign gRPC client can INVOKE,
// use example/server_protobuf.dart, which pairs the descriptor with
// RpcBinaryCodec.
//
// Run:
//   fvm dart run example/server.dart
//
// Test with grpcurl — reflection, which is what this example is about:
//   grpcurl -plaintext localhost:50051 list
//   grpcurl -plaintext localhost:50051 list echo.v1.EchoService
//   grpcurl -plaintext localhost:50051 describe echo.v1.EchoService
//   grpcurl -plaintext localhost:50051 describe echo.v1.EchoService.Echo

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

// ---------------------------------------------------------------------------
// Model types
// ---------------------------------------------------------------------------

class EchoRequest implements IRpcSerializable {
  final String message;
  final int count;
  EchoRequest({required this.message, required this.count});
  factory EchoRequest.fromJson(Map<String, dynamic> j) => EchoRequest(
    message: j['message'] as String? ?? '',
    count: j['count'] as int? ?? 0,
  );
  @override
  Map<String, dynamic> toJson() => {'message': message, 'count': count};
}

class EchoResponse implements IRpcSerializable {
  final String message;
  final int index;
  EchoResponse({required this.message, required this.index});
  factory EchoResponse.fromJson(Map<String, dynamic> j) => EchoResponse(
    message: j['message'] as String? ?? '',
    index: j['index'] as int? ?? 0,
  );
  @override
  Map<String, dynamic> toJson() => {'message': message, 'index': index};
}

// ---------------------------------------------------------------------------
// Contract
// ---------------------------------------------------------------------------

final _reqCodec = RpcCodec<EchoRequest>.withDecoder(EchoRequest.fromJson);
final _resCodec = RpcCodec<EchoResponse>.withDecoder(EchoResponse.fromJson);

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
// Reflection descriptor, built from field and method metadata.
//
// For protobuf services, use .addMessageBytes() / .addServiceBytes() with
// bytes from the generated .pbjson.dart file instead.
// ---------------------------------------------------------------------------

final _echoDescriptor =
    RpcFileDescriptorBuilder(name: 'echo.proto', package: 'echo.v1')
        .addMessage(
          RpcMessageDescriptor(
            name: 'EchoRequest',
            fields: [
              RpcFieldDescriptor(
                name: 'message',
                number: 1,
                type: RpcFieldType.typeString,
              ),
              RpcFieldDescriptor(
                name: 'count',
                number: 2,
                type: RpcFieldType.typeInt32,
              ),
            ],
          ),
        )
        .addMessage(
          RpcMessageDescriptor(
            name: 'EchoResponse',
            fields: [
              RpcFieldDescriptor(
                name: 'message',
                number: 1,
                type: RpcFieldType.typeString,
              ),
              RpcFieldDescriptor(
                name: 'index',
                number: 2,
                type: RpcFieldType.typeInt32,
              ),
            ],
          ),
        )
        .addService(
          name: 'EchoService',
          methods: [
            RpcMethodDescriptor(
              name: 'Echo',
              inputType: '.echo.v1.EchoRequest',
              outputType: '.echo.v1.EchoResponse',
            ),
            RpcMethodDescriptor(
              name: 'EchoStream',
              inputType: '.echo.v1.EchoRequest',
              outputType: '.echo.v1.EchoResponse',
              serverStreaming: true,
            ),
          ],
        )
        .build();

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() async {
  final registry = RpcReflectionRegistry()..addFileDescriptor(_echoDescriptor);

  final server = RpcHttp2Server(
    host: '0.0.0.0',
    port: 50051,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(EchoResponderContract());
      registry.attachTo(endpoint);
      // RpcHttp2Server starts the endpoint after this callback returns.
    },
  );

  await server.start();
  stderr.writeln('Server listening on :50051');
  stderr.writeln('Try (reflection — this service speaks CBOR, not protobuf):');
  stderr.writeln('  grpcurl -plaintext localhost:50051 list');
  stderr.writeln(
    '  grpcurl -plaintext localhost:50051 list echo.v1.EchoService',
  );
  stderr.writeln(
    '  grpcurl -plaintext localhost:50051 describe echo.v1.EchoService',
  );
  stderr.writeln(
    'To INVOKE from grpcurl, run example/server_protobuf.dart instead.',
  );

  final done = Completer<void>();
  ProcessSignal.sigterm.watch().listen((_) => done.complete());
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;

  await server.stop();
}
