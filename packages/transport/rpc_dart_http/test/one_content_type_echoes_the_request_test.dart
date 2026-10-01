// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_completeResponse` seeded its header map with `application/grpc+proto` and
// then merged the response metadata, which carries core's bare
// `application/grpc` -- and the merge turns a repeated name into a LIST. So
// every response left here with TWO content-type values, and the first of them
// claimed protobuf however the call was encoded.
//
// Read through `handler` and `headersAll`, which is shelf's multi-value view:
// dart:io's adapter keeps the last value, so a real socket would measure the
// adapter's flattening rather than what this code produced.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: RpcCodec(RpcString.fromJson),
      responseCodec: RpcCodec(RpcString.fromJson),
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

/// The content-type field LINES a real peer receives over a real socket.
///
/// `dart:io`'s adapter collapses a multi-value shelf header to one line, which
/// is why the tests above read the shelf [Response] instead; this one is here
/// for the half only a socket can show — which subtype the caller is told.
Future<List<String>> _wireContentTypes(String requestContentType) async {
  final transport = RpcHttpResponderTransport();
  final responder = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_Echo())
    ..start();
  final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
  final client = HttpClient();
  addTearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await responder.close();
  });

  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:${server.port}/Svc/echo'),
  );
  request.headers.set(RpcHeaders.contentType, requestContentType);
  request.add(
    RpcMessageFrame.encode(RpcCodec(RpcString.fromJson).serialize('x'.rpc)),
  );
  final response = await request.close();
  await response.drain<void>();
  return response.headers[RpcHeaders.contentType] ?? const [];
}

/// Answers one request by hand, so the test owns the response metadata.
///
/// The endpoint is deliberately absent: what matters is which headers reach
/// [RpcHttpResponderTransport.sendMetadata], and a pipeline in between can only
/// make that harder to state. [coreSendsAContentType] below pins the half the
/// pipeline contributes.
Future<Response> _respond({
  required String requestContentType,
  required List<RpcHeader> responseHeaders,
}) async {
  final transport = RpcHttpResponderTransport();
  addTearDown(transport.close);

  final opened = Completer<int>();
  final sub = transport.incomingMessages.listen((message) {
    if (!opened.isCompleted) opened.complete(message.streamId);
  });
  addTearDown(sub.cancel);

  final answering = Future<Response>.value(
    transport.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/Svc/echo'),
        headers: {'content-type': requestContentType},
        body: RpcMessageFrame.encode(Uint8List.fromList(utf8.encode('"x"'))),
      ),
    ),
  );

  final streamId = await opened.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail('the request never opened a stream'),
  );
  await transport.sendMetadata(streamId, RpcMetadata(responseHeaders));
  await transport.sendMessage(
    streamId,
    RpcMessageFrame.encode(Uint8List.fromList(utf8.encode('"x"'))),
  );
  await transport.finishSending(streamId);

  return answering.timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail('the response never completed'),
  );
}

/// The response metadata core's responder pipeline really sends.
final coreSendsAContentType = RpcMetadata.forServerInitialResponse().headers;

List<String> _contentTypes(Response response) =>
    response.headersAll[RpcHeaders.contentType] ?? const [];

void main() {
  test('core really does send a content-type of its own', () {
    // The other half of the collision. Were this to stop being true the witness
    // below would pass for the wrong reason.
    expect(
      coreSendsAContentType
          .where((h) => h.name == RpcHeaders.contentType)
          .map((h) => h.value),
      [RpcHeaders.contentTypeGrpc],
    );
  });

  test('WITNESS a response carries exactly ONE content-type', () async {
    final response = await _respond(
      requestContentType: 'application/grpc',
      responseHeaders: coreSendsAContentType,
    );

    expect(
      _contentTypes(response),
      ['application/grpc'],
      reason:
          "the seeded value and the pipeline's were merged into a list; "
          'an adapter that emits both puts two content-types on the wire',
    );
  });

  test('WITNESS a +json call is not told its answer is protobuf', () async {
    final response = await _respond(
      requestContentType: 'application/grpc+json',
      responseHeaders: coreSendsAContentType,
    );

    expect(_contentTypes(response), ['application/grpc+json']);
  });

  test('the subtype is rebuilt, not echoed', () async {
    // The request's content-type is peer input and the gate above it only
    // checks the PREFIX, so `application/grpc` followed by anything reaches
    // here. A response header is where that would matter.
    final notTokens = <String>[
      'application/grpc+json, text/plain',
      'application/grpc+js on',
      'application/grpc+"json"',
      'application/grpc+',
    ];
    for (final hostile in notTokens) {
      final response = await _respond(
        requestContentType: hostile,
        responseHeaders: coreSendsAContentType,
      );
      expect(
        _contentTypes(response),
        ['application/grpc'],
        reason: 'a subtype that is not a token degrades to the bare form',
      );
    }
  });

  test('a parameterised request keeps its subtype', () async {
    // Proxies append `; charset=...`, and the parameter is not part of the
    // subtype. Upper case because RFC 9110 s8.3.1 permits it and
    // `content_type_case_test` already pins that the gate accepts it.
    final response = await _respond(
      requestContentType: 'Application/GRPC+PROTO; charset=utf-8',
      responseHeaders: coreSendsAContentType,
    );

    expect(_contentTypes(response), ['application/grpc+proto']);
  });

  test('GUARD a content-type in the metadata never reaches the wire', () async {
    // Whatever case it arrives in: `RpcHeader` does not lowercase its name, so
    // a mixed-case one would slip past a `==` and restore the list.
    final response = await _respond(
      requestContentType: 'application/grpc+json',
      responseHeaders: const [
        RpcHeader('Content-Type', 'text/plain'),
        RpcHeader(RpcHeaders.contentType, 'application/grpc'),
      ],
    );

    expect(_contentTypes(response), ['application/grpc+json']);
  });

  test('GUARD other repeated response headers are still a list', () async {
    // The skip sits inside the merge loop, which exists so a repeated custom
    // key survives as two values. Removing content-type from it must not
    // remove that.
    final response = await _respond(
      requestContentType: 'application/grpc',
      responseHeaders: const [
        RpcHeader('x-trace', 'alpha'),
        RpcHeader('x-trace', 'beta'),
      ],
    );

    expect(response.headersAll['x-trace'], ['alpha', 'beta']);
    expect(_contentTypes(response), ['application/grpc']);
  });

  test('over a real socket a +json caller is told +json', () async {
    // What the duplicate cost on dart:io: its adapter kept the LAST value, so a
    // peer never saw two lines and never saw `+proto` either — it saw the bare
    // form for every call, whatever was asked for.
    expect(await _wireContentTypes('application/grpc+json'), [
      'application/grpc+json',
    ]);
    expect(await _wireContentTypes('application/grpc'), ['application/grpc']);
  });
}
