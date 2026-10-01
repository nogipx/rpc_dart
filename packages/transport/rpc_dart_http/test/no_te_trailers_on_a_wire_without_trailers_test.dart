// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `te: trailers` signals trailer support, and this wire format sends no trailers:
// the caller's own class doc says every response header, `grpc-status` among them,
// is an ordinary header. `te` is also hop-by-hop, so a proxy strips it and no
// responder can rely on it, and it is a forbidden header name in a browser.
//
// What this file reads is the request metadata the responder TRANSPORT builds,
// which is where the aggregate `maxMetadataBytes` check counts bytes. It stops
// there: core's `_createContextFromMessage` excludes `te` by name, so no handler
// ever saw it — and that exclusion has to stay, because `rpc_dart_http2` sends the
// header and the gRPC HTTP/2 spec requires it to.
//
// The browser-console half of the lead needs a browser and is not read here.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

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

/// Every request-metadata header name one real call delivers to the responder.
Future<List<String>> _headersDelivered({
  Map<String, String> callerMetadata = const {},
}) async {
  final responderTransport = RpcHttpResponderTransport();
  final responder = RpcResponderEndpoint(transport: responderTransport)
    ..registerServiceContract(_Echo())
    ..start();

  final seen = <String>[];
  final arrived = Completer<void>();
  final sub = responderTransport.incomingMessages.listen((message) {
    final metadata = message.metadata;
    if (metadata == null) return;
    seen.addAll(metadata.headers.map((h) => h.name));
    if (!arrived.isCompleted) arrived.complete();
  });

  final server = await shelf_io.serve(
    responderTransport.handler,
    '127.0.0.1',
    0,
  );
  final callerTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final caller = RpcCallerEndpoint(transport: callerTransport);
  addTearDown(() async {
    await sub.cancel();
    await caller.close();
    await callerTransport.close();
    await server.close(force: true);
    await responder.close();
    await responderTransport.close();
  });

  await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'echo',
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
    transferMode: RpcDataTransferMode.codec,
    context: callerMetadata.isEmpty
        ? null
        : RpcContext.empty().withAdditionalHeaders(callerMetadata),
  );

  await arrived.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => fail('no request metadata arrived'),
  );
  return seen;
}

void main() {
  test('WITNESS no `te` reaches the responder as request metadata', () async {
    final delivered = await _headersDelivered();

    expect(
      delivered,
      isNot(contains(RpcHeaders.te)),
      reason:
          'the header signals trailer support on a wire that sends no '
          'trailers, and every byte of it is charged to maxMetadataBytes',
    );
  });

  test('GUARD the headers this wire format DOES need still arrive', () async {
    // Load-bearing: removing a header must not have removed the request's own.
    final delivered = await _headersDelivered();

    expect(delivered, contains(RpcHeaders.contentType));
    expect(delivered, contains('content-length'));
  });

  test("GUARD a caller's own metadata is untouched", () async {
    final delivered = await _headersDelivered(
      callerMetadata: const {'x-caller-said': 'hello'},
    );

    expect(delivered, contains('x-caller-said'));
  });
}
