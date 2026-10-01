// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_PendingCall.bodyBuffer` holds the request body until the whole call can be
// fired, which over HTTP/1.1 is always: the wire cannot flush before the end. A
// growable `List<int>` holds a WORD-SIZED slot per byte on the VM and
// `Uint8List.fromList` then copies it again, so the buffer costs several times the
// body — for a size the application chooses.
//
// Measured as RSS by the probe. Pinned here as IDENTITY, which is the same fact
// stated deterministically: with `BytesBuilder(copy: false)` a single-chunk body
// reaches `bodyBytes` as the caller's own `Uint8List`, so a copy anywhere on that
// path breaks this test.

@TestOn('vm')
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

/// Captures the request body and answers a Trailers-Only `grpc-status: 0`.
class _CapturingClient extends http.BaseClient {
  Uint8List? sent;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent = (request as http.Request).bodyBytes;
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      200,
      headers: const {
        'content-type': 'application/grpc+proto',
        'grpc-status': '0',
      },
      request: request,
    );
  }
}

/// Sends [chunks] through one call and returns what reached the wire.
Future<({Uint8List sent, _CapturingClient client})> _send(
  List<Uint8List> chunks,
) async {
  final client = _CapturingClient();
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://localhost:1',
    httpClient: client,
  );
  addTearDown(transport.close);

  final streamId = transport.createStream();
  final done = Completer<void>();
  final sub = transport.getMessagesForStream(streamId).listen((message) {
    if (message.isEndOfStream && !done.isCompleted) done.complete();
  });
  addTearDown(sub.cancel);

  await transport.sendMetadata(
    streamId,
    RpcMetadata.forClientRequest('Svc', 'echo'),
  );
  for (final chunk in chunks) {
    await transport.sendMessage(streamId, chunk);
  }
  await transport.finishSending(streamId);

  await done.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail('the call never ended'),
  );
  return (sent: client.sent!, client: client);
}

void main() {
  test('WITNESS a single-chunk body reaches the wire uncopied', () async {
    final payload = Uint8List.fromList(
      List<int>.generate(4096, (i) => i % 256),
    );

    final answered = await _send([payload]);

    expect(
      identical(answered.sent, payload),
      isTrue,
      reason:
          'the buffer hands the payload over; a List<int> round trip through '
          'Uint8List.fromList makes two copies of it',
    );
  });

  test('GUARD two chunks still arrive joined, in order', () async {
    // The arm a zero-copy shortcut would break: with more than one chunk there
    // is nothing to hand over and the bytes must be concatenated.
    final first = Uint8List.fromList(const [1, 2, 3]);
    final second = Uint8List.fromList(const [4, 5]);

    final answered = await _send([first, second]);

    expect(answered.sent, [1, 2, 3, 4, 5]);
    expect(identical(answered.sent, first), isFalse);
  });

  test('GUARD an empty body is still an empty body', () async {
    final answered = await _send([]);

    expect(answered.sent, isEmpty);
  });

  test('GUARD the bytes themselves are intact', () async {
    // Identity without content would pass if the buffer handed over the WRONG
    // array.
    final payload = Uint8List.fromList(
      List<int>.generate(1024, (i) => (i * 7) % 256),
    );

    final answered = await _send([payload]);

    expect(answered.sent.length, 1024);
    expect(answered.sent[0], 0);
    expect(answered.sent[1], 7);
    expect(answered.sent[1023], (1023 * 7) % 256);
  });
}
