// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `package:http`'s `request.headers` is a `Map<String, String>`, so assigning twice
// for one metadata key silently kept the second value and dropped the first —
// metadata a caller set, gone before the request left the process.
//
// Joined with `,` instead, which is the delimiter PROTOCOL-HTTP2 names for exactly
// this: duplicate header names "may have their values joined with ',' as the
// delimiter and be considered semantically equivalent". It is also what this
// transport's own response side splits on, so the two directions now agree.
//
// Read at the server, and COUNTED. A list of one comma-bearing value and a list of
// two values have the same `toString()` in Dart, so an unquoted print cannot answer
// this question — which is how the first reading of the response half of this defect
// came out backwards.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

Future<({List<String>? tag, HttpServer server})> _send(
  List<String> values,
) async {
  List<String>? tag;
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    await req.drain<void>();
    tag = req.headers['x-tag'];
    req.response.headers.contentType = ContentType('application', 'grpc+proto');
    req.response.headers.set('grpc-status', '0');
    await req.response.close();
  });

  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  transport.incomingMessages.listen((_) {}, onError: (Object _) {});
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await server.close(force: true);
  });

  final id = transport.createStream();
  // `methodPath` is a FIELD, not a header: rebuilding from `.headers` alone drops it
  // and the frame becomes a control frame that fires no request at all.
  final base = RpcMetadata.forClientRequest('Svc', 'm');
  await transport.sendMetadata(
    id,
    RpcMetadata([
      ...base.headers,
      for (final v in values) RpcHeader('x-tag', v),
    ], methodPath: base.methodPath),
  );
  await transport
      .sendMessage(
        id,
        RpcMessageFrame.encode(Uint8List.fromList(<int>[1])),
        endStream: true,
      )
      .catchError((Object _) {});
  await Future<void>.delayed(const Duration(milliseconds: 400));

  return (tag: tag, server: server);
}

void main() {
  test(
    'WITNESS: two values of one metadata key both reach the server',
    () async {
      final run = await _send(['first', 'second']);

      // dart:io reports one field line, so the values arrive joined. Both must be
      // THERE; which of the two encodings the peer sees is the spec's business.
      expect(
        run.tag?.join(',').split(','),
        ['first', 'second'],
        reason:
            'the first value was dropped before the request left: assigning twice '
            'into a Map<String, String> keeps only the last',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CONTROL: one value must be unchanged — not wrapped, not given a stray comma by
  // the join. A fix that always appended a delimiter would pass the witness.
  test(
    'CONTROL: a single value is sent exactly as given',
    () async {
      final run = await _send(['only']);

      expect(run.tag, ['only']);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
