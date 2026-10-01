// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcHttpResponderTransport`'s own checks — the request body, the metadata
// block, the method path, concurrent requests — all sit behind
// `if (policy != null)`, and the class's example constructs it with no policy
// before handing the handler to `shelf_io.serve`. So the documented setup is the
// one with no limits, while `RpcHttpServer` three files over defaults the same
// parameter to `const RpcSecurityPolicy()`.
//
// `securityPolicy: null` still means exactly that, and is pinned here too: an
// opt-out that quietly stopped working would be the same defect in the other
// direction.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _mib = 1024 * 1024;

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

/// One gRPC frame header declaring [length] payload bytes, uncompressed.
Uint8List _frameHeader(int length) {
  final header = Uint8List(5);
  header[0] = 0;
  header.buffer.asByteData().setUint32(1, length);
  return header;
}

/// Serves [transport] and uploads [payloadMib] MiB as one declared frame.
Future<int> _uploadThrough(
  RpcHttpResponderTransport transport, {
  required int payloadMib,
  Map<String, String> extraHeaders = const {},
}) async {
  final responder = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_Echo())
    ..start();
  final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
  final client = HttpClient();
  addTearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await responder.close();
    await transport.close();
  });

  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:${server.port}/Svc/echo'),
  );
  request.headers.set(RpcHeaders.contentType, 'application/grpc');
  extraHeaders.forEach(request.headers.set);
  final payload = payloadMib * _mib;
  request.headers.contentLength = payload + 5;
  request.add(_frameHeader(payload));
  final chunk = Uint8List(_mib);
  await request.addStream(
    Stream<List<int>>.fromIterable(
      Iterable<List<int>>.generate(payloadMib, (_) => chunk),
    ),
  );
  final response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

void main() {
  // The default `maxMessageLengthBytes` is 16 MiB, so 20 is over it and 1 is
  // comfortably under.
  test('WITNESS the documented construction bounds the request body', () async {
    expect(
      await _uploadThrough(RpcHttpResponderTransport(), payloadMib: 20),
      413,
      reason: 'the transport own checks must apply without being asked for',
    );
  });

  test('GUARD a body inside the default limit still goes through', () async {
    // Load-bearing: a default that refused everything would pass the witness.
    // 200 and not a gRPC status, because the pipeline answers the call itself —
    // 1 MiB of zeros is not a message this codec can read.
    expect(
      await _uploadThrough(RpcHttpResponderTransport(), payloadMib: 1),
      200,
    );
  });

  test('GUARD securityPolicy: null is still a real opt-out', () async {
    expect(
      await _uploadThrough(
        RpcHttpResponderTransport(securityPolicy: null),
        payloadMib: 20,
      ),
      200,
      reason:
          'null disables this transport own limits; the pipeline still '
          'refuses the message, which is why this is a 200',
    );
  });

  test('the other checks came on with it', () async {
    // The body is one of four things `if (policy != null)` guarded. The metadata
    // bound is the cheapest of the rest to drive: `maxMetadataBytes` is 64 KiB.
    final oversized = {for (var i = 0; i < 16; i++) 'x-pad-$i': 'p' * 6 * 1024};

    expect(
      await _uploadThrough(
        RpcHttpResponderTransport(),
        payloadMib: 1,
        extraHeaders: oversized,
      ),
      400,
    );
    expect(
      await _uploadThrough(
        RpcHttpResponderTransport(securityPolicy: null),
        payloadMib: 1,
        extraHeaders: oversized,
      ),
      200,
      reason: 'the same block with the checks off',
    );
  });

  test('GUARD RpcHttpServer already defaulted the same way', () async {
    // The sibling this fix copies. If its default ever moves, the two are out of
    // step again and that is the defect, whichever way round it is.
    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (endpoint) {
        endpoint.registerServiceContract(_Echo());
        endpoint.start();
      },
    );
    await server.start();
    await server.afterModulesStart();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.actualPort}/Svc/echo'),
    );
    request.headers.set(RpcHeaders.contentType, 'application/grpc');
    final payload = 20 * _mib;
    request.headers.contentLength = payload + 5;
    request.add(_frameHeader(payload));
    final chunk = Uint8List(_mib);
    await request.addStream(
      Stream<List<int>>.fromIterable(
        Iterable<List<int>>.generate(20, (_) => chunk),
      ),
    );
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, 413);
  });
}
