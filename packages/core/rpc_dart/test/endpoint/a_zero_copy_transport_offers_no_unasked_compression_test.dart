// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A codec call on a zero-copy transport (the in-memory pair, isolate) is framed
// like any other, so what the caller offers in grpc-accept-encoding decides
// whether every response is gzipped. A caller that did not enable compression
// must offer identity there as it does on a network transport.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.seen) : super('Svc', dataTransferMode: RpcDataTransferMode.codec);

  final List<String?> seen;

  void _note(RpcContext? context) =>
      seen.add(context?.getHeader(RpcHeaders.grpcAcceptEncoding));

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        _note(context);
        return r;
      },
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 's',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        _note(context);
        yield r;
      },
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (rs, {RpcContext? context}) async {
        _note(context);
        return (await rs.toList()).first;
      },
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'b',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (rs, {RpcContext? context}) async* {
        _note(context);
        yield* rs;
      },
    );
  }
}

/// What the responder saw in grpc-accept-encoding, one entry per shape.
Future<List<String?>> _offered({required bool compressionEnabled}) async {
  final (client, server) = RpcChannelTransport.memoryPair();
  expect(client.supportsZeroCopy, isTrue);
  final seen = <String?>[];
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(seen))
    ..start();
  final caller = RpcCallerEndpoint(
    transport: client,
    compressionEnabled: compressionEnabled,
  );
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final q = 'q'.rpc;
  await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'u',
    request: q,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  await caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 's',
        request: q,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .toList();
  await caller.clientStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'c',
    requestCodec: _codec,
    responseCodec: _codec,
  )(Stream.value(q));
  await caller
      .bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'b',
        requests: Stream.value(q),
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .toList();
  return seen;
}

void main() {
  test(
    'without compression enabled, every shape offers identity only',
    () async {
      expect(await _offered(compressionEnabled: false), [
        'identity',
        'identity',
        'identity',
        'identity',
      ]);
    },
  );

  // What is registered: gzip on the VM, identity alone where no gzip codec is
  // (the web).
  test(
    'with compression enabled, every shape offers what is registered',
    () async {
      final registered = RpcGrpcCompression.supportedEncodings().join(',');
      expect(await _offered(compressionEnabled: true), [
        registered,
        registered,
        registered,
        registered,
      ]);
    },
  );
}
