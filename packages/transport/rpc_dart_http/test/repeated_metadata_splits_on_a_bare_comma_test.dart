// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-09 item 1, the HTTP/1.1 half.
//
// package:http hands responses back as `Map<String, String>`, so repeated
// header lines arrive already combined. RFC 9110 s5.3 permits that only for a
// field whose definition allows recombination as a comma-separated list, and
// PROTOCOL-HTTP2 makes Custom-Metadata exactly that field: duplicates "may have
// their values joined with ',' as the delimiter and be considered semantically
// equivalent".
//
// So splitting is right. The DELIMITER was wrong: `split(', ')` never split a
// peer that joined with the bare comma gRPC's own text names, and RFC 9110 only
// RECOMMENDS comma-SP.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

/// Answers every request with a 200 carrying [headers], verbatim.
class _FixedHeadersClient extends http.BaseClient {
  _FixedHeadersClient(this.headers);

  final Map<String, String> headers;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      200,
      headers: headers,
      request: request,
    );
  }
}

/// The initial-metadata headers a call receives when the peer's response
/// carries [headerValue] under `x-trace`.
Future<List<RpcHeader>> _headersFor(String headerValue) async {
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://localhost:1',
    httpClient: _FixedHeadersClient({
      'content-type': 'application/grpc+proto',
      'x-trace': headerValue,
    }),
  );
  addTearDown(transport.close);

  final streamId = transport.createStream();
  final seen = <RpcHeader>[];
  final done = Completer<void>();
  final sub = transport.getMessagesForStream(streamId).listen((message) {
    final metadata = message.metadata;
    if (metadata != null) {
      seen.addAll(metadata.headers.where((h) => h.name == 'x-trace'));
    }
    if (message.isEndOfStream && !done.isCompleted) done.complete();
  });
  addTearDown(sub.cancel);

  await transport.sendMetadata(
    streamId,
    RpcMetadata.forClientRequest('Svc', 'echo'),
  );
  await transport.sendMessage(streamId, utf8.encode('x'));
  await transport.finishSending(streamId);

  await done.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail('the call never ended'),
  );
  return seen;
}

void main() {
  test('WITNESS: values joined with a BARE comma are split', () async {
    expect(
      (await _headersFor('alpha,beta')).map((h) => h.value).toList(),
      ['alpha', 'beta'],
      reason:
          'gRPC names "," as the delimiter, so a peer that follows it was '
          'never split at all and two metadata values arrived as one string',
    );
  });

  test('GUARD: comma-space still splits, as it always did', () async {
    expect((await _headersFor('alpha, beta')).map((h) => h.value).toList(), [
      'alpha',
      'beta',
    ]);
  });

  test('GUARD: an ordinary single value is untouched', () async {
    expect((await _headersFor('alpha')).map((h) => h.value).toList(), [
      'alpha',
    ]);
  });
}
