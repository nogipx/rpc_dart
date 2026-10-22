// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A responder compresses its responses only when its own compressionEnabled
// says so. A client that merely accepts gzip does not switch it on: the server
// owner decides what its CPU is spent on. A peer endpoint's flag covers its
// responses too.
//
// Observed by counting the codec's compress() calls on the server. The caller
// sends `grpc-accept-encoding: gzip` without compressing its own request, so
// every call counted is a response.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _compressCalls = 0;

/// Self-inverse, so it round-trips on every platform, dart2js included, where
/// the built-in gzip is absent.
final class _CountingXor implements RpcCompressionCodec {
  const _CountingXor();

  @override
  Uint8List compress(Uint8List data) {
    _compressCalls++;
    return _xor(data);
  }

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) => _xor(data);

  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5a]);
}

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => req,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'twice',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        yield req;
        yield req;
      },
    );
  }
}

/// Server compress() calls for one unary call and one two-response stream.
Future<int> _compressedResponses(
  RpcResponderEndpoint Function(IRpcTransport) server,
) async {
  _compressCalls = 0;
  final (clientTransport, serverTransport) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  final responder = server(serverTransport)
    ..registerServiceContract(_Echo())
    ..start();
  final accepts = RpcContext.withHeaders({
    RpcHeaders.grpcAcceptEncoding: RpcGrpcCompression.gzip,
  });
  final request = ('a' * 64).rpc;
  try {
    final reply = await caller.unary<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'echo',
      request: request,
      requestCodec: _codec,
      responseCodec: _codec,
      context: accepts,
    );
    final stream = await caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'twice',
          request: request,
          requestCodec: _codec,
          responseCodec: _codec,
          context: accepts,
        )
        .toList();
    expect(reply, request);
    expect(stream, [request, request]);
    return _compressCalls;
  } finally {
    await caller.close();
    await responder.close();
  }
}

void main() {
  setUpAll(
    () => RpcGrpcCompression.register(
      RpcGrpcCompression.gzip,
      const _CountingXor(),
    ),
  );

  test('a responder with compression off compresses nothing', () async {
    expect(
      await _compressedResponses((t) => RpcResponderEndpoint(transport: t)),
      0,
    );
  });

  test(
    'CONTROL: a responder with compression on compresses each response',
    () async {
      expect(
        await _compressedResponses(
          (t) => RpcResponderEndpoint(transport: t, compressionEnabled: true),
        ),
        3,
      );
    },
  );

  test('a peer endpoint compresses its responses by its own flag', () async {
    expect(await _compressedResponses((t) => RpcPeerEndpoint(transport: t)), 0);
    expect(
      await _compressedResponses(
        (t) => RpcPeerEndpoint(transport: t, compressionEnabled: true),
      ),
      3,
    );
  });
}
