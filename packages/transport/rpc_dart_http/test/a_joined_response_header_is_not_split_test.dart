// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller split EVERY response header on `,`, and that is right for exactly one
// field. PROTOCOL-HTTP2 makes Custom-Metadata recombinable — duplicates "may have
// their values joined with ',' as the delimiter and be considered semantically
// equivalent" — but nothing on the wire says which key is Custom-Metadata. So
// `date` arrived as "Mon" plus "29 Sep 2026 12:00:00 GMT", and
// `www-authenticate: Basic realm="one, two"` was cut inside its quoted string.
//
// The fix is to stop splitting: a receiver that wants the parts knows its own key's
// definition and can split, and the alternative — a list of standard fields to
// exempt — is this same defect for every field missing from it, silently, forever.
//
// BREAKING: an application that received two values for a repeated custom key now
// receives one joined value.
//
// These tests asserted the opposite until round 545. They were pinning the behaviour
// being removed, so the harness stayed and the assertions inverted.

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

/// Every metadata header a call receives when the peer answers with [headers].
///
/// `package:http` types a response's headers as `Map<String, String>`, so a
/// repeated field line is ALREADY joined before this transport sees it — which is
/// why the fixture is a map and why "two values" can only come from splitting.
Future<List<RpcHeader>> _received(Map<String, String> headers) async {
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://localhost:1',
    httpClient: _FixedHeadersClient({
      'content-type': 'application/grpc+proto',
      ...headers,
    }),
  );
  addTearDown(transport.close);

  final streamId = transport.createStream();
  final seen = <RpcHeader>[];
  final done = Completer<void>();
  final sub = transport.getMessagesForStream(streamId).listen((message) {
    final metadata = message.metadata;
    if (metadata != null) seen.addAll(metadata.headers);
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

List<String> _valuesOf(List<RpcHeader> headers, String name) =>
    headers.where((h) => h.name == name).map((h) => h.value).toList();

void main() {
  test('WITNESS a repeated CUSTOM key arrives as ONE joined value', () async {
    // The arm that tells "stopped splitting" from "kept a list of standard fields
    // to exempt". Custom-Metadata is the one field whose definition DOES permit
    // recombination, so an exemption list would still split this one.
    final received = await _received({'x-trace': 'alpha,beta'});

    expect(
      _valuesOf(received, 'x-trace'),
      ['alpha,beta'],
      reason:
          "splitting is the receiver's job: only it knows whether this key's "
          'comma separates values or belongs inside one',
    );
  });

  test(
    'WITNESS a standard field whose value CONTAINS a comma is intact',
    () async {
      // The arm that fails on the old behaviour. `date`'s comma follows the
      // weekday and `www-authenticate`'s sits inside a quoted string; neither
      // field permits list recombination at all.
      final received = await _received({
        'date': 'Mon, 29 Sep 2026 12:00:00 GMT',
        'www-authenticate': 'Basic realm="one, two"',
      });

      expect(_valuesOf(received, 'date'), ['Mon, 29 Sep 2026 12:00:00 GMT']);
      expect(_valuesOf(received, 'www-authenticate'), [
        'Basic realm="one, two"',
      ]);
    },
  );

  test('GUARD an ordinary single value is untouched', () async {
    expect(_valuesOf(await _received({'x-trace': 'alpha'}), 'x-trace'), [
      'alpha',
    ]);
  });

  test('GUARD the trailer headers still route to the trailer', () async {
    // The routing sits in the same block the fix rewrote: `grpc-status` and
    // `grpc-message` go to the trailing metadata and everything else to the
    // initial. Neither can contain a comma, so they were never at risk from the
    // split — they are at risk from the edit.
    final received = await _received({'grpc-status': '0', 'x-trace': 'alpha'});

    expect(_valuesOf(received, 'grpc-status'), ['0']);
    expect(_valuesOf(received, 'x-trace'), ['alpha']);
  });
}
