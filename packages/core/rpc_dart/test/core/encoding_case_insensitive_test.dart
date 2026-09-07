// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RFC 9110 s8.4.1: "All content-coding values are case-insensitive", and gRPC
// defines grpc-encoding as a Content-Coding. The registry compared exactly, so
// legal spellings were refused on BOTH sides:
//
//     isSupported('gzip')     -> true      isSupported('GZIP')     -> false
//     isSupported('identity') -> true      isSupported('IDENTITY') -> false
//     a call sending grpc-encoding: IDENTITY -> RpcException, refused by our own
//                                               caller before reaching the wire
//
// and a foreign client sending `GZIP` was answered UNIMPLEMENTED for a request
// the server could have served perfectly well.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

class _NoopCodec implements RpcCompressionCodec {
  @override
  Uint8List compress(Uint8List data) => data;

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) => data;
}

void main() {
  test('identity is recognised in any case', () {
    expect(RpcGrpcCompression.isSupported('identity'), isTrue);
    expect(RpcGrpcCompression.isSupported('IDENTITY'), isTrue);
    expect(RpcGrpcCompression.isSupported('Identity'), isTrue);
  });

  test('a registered codec is found in any case', () {
    RpcGrpcCompression.register('x-test-codec', _NoopCodec());
    addTearDown(() => RpcGrpcCompression.unregister('x-test-codec'));

    expect(RpcGrpcCompression.isSupported('x-test-codec'), isTrue);
    expect(RpcGrpcCompression.isSupported('X-TEST-CODEC'), isTrue);
    expect(RpcGrpcCompression.isSupported('X-Test-Codec'), isTrue);
  });

  test('registering under one case and asking in another agrees', () {
    // Both halves normalise, so the peer's spelling and the application's
    // spelling do not have to match.
    RpcGrpcCompression.register('X-MIXED-Case', _NoopCodec());
    addTearDown(() => RpcGrpcCompression.unregister('x-mixed-case'));

    expect(RpcGrpcCompression.isSupported('x-mixed-case'), isTrue);

    // The selection returns the PEER's spelling, not a normalised one, and that
    // is fine: it goes back out as the grpc-encoding header, where the peer
    // reads it, and every lookup normalises anyway. What matters is that a
    // selection happens at all and that the result is usable.
    final selected = RpcGrpcCompression.selectResponseEncoding(
      'identity, X-Mixed-Case',
    );
    expect(selected, isNotNull);
    expect(RpcGrpcCompression.isSupported(selected!), isTrue);
    expect(
      RpcGrpcCompression.compress(
        Uint8List.fromList([1, 2, 3]),
        encoding: selected,
      ),
      isNotEmpty,
      reason: 'whatever spelling comes back must be usable for compression',
    );
  });

  test('a call carrying an uppercase grpc-encoding is served', () async {
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Svc());
    responder.start();
    addTearDown(() async {
      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });

    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'ping',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withHeaders({
        RpcHeaders.grpcEncoding: 'IDENTITY',
      }).withTimeout(const Duration(seconds: 5)),
    );

    expect(answer.value, 'pong');
  });

  test('GUARD: an unknown encoding is still refused', () {
    // Load-bearing: normalising must widen the match to CASE only. A codec
    // nobody registered has to stay unsupported, or the UNIMPLEMENTED path that
    // tells a peer what IS supported would never fire.
    expect(RpcGrpcCompression.isSupported('br'), isFalse);
    expect(RpcGrpcCompression.isSupported('BR'), isFalse);
    expect(RpcGrpcCompression.selectResponseEncoding('br, snappy'), isNull);
  });
}
