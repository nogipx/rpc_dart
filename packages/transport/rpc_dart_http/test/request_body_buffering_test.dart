// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The responder buffered a request body into `final bytes = <int>[]` and copied
// it with `Uint8List.fromList`. A Dart list holds WORD-SIZED elements, so the
// buffer cost several times the body and the copy doubled it again — for a size
// the PEER chooses, bounded only by maxMessageLengthBytes (16 MiB by default).
// Measured over identical chunk streams:
//
//      4 MiB body :  78 ms, +112.8 MiB peak  ->  0 ms, ~0
//     16 MiB body : 303 ms, +264.2 MiB peak  ->  1 ms, ~0
//
// and end to end, median of five requests each:
//
//      4 MiB body :  80 ms -> 20 ms
//      8 MiB body : 158 ms -> 37 ms
//     16 MiB body : 285 ms -> 44 ms
//
// This file does not assert timings — they are the reason for the change, not a
// property to pin on shared CI. What it pins is that the LIMIT still behaves
// exactly as before, in both directions, since that is what a buffering rewrite
// can quietly break.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._seen) : super('Svc');

  final List<int> _seen;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'sink',
      handler: (r, {RpcContext? context}) async {
        _seen.add(r.value.length);
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({int port, List<int> seen});

Future<_Rig> _serve({required int limit}) async {
  final seen = <int>[];
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: RpcSecurityPolicy(maxMessageLengthBytes: limit),
    onEndpointCreated: (e) {
      e.registerServiceContract(_Svc(seen));
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();
  addTearDown(server.stop);
  return (port: server.actualPort!, seen: seen);
}

/// POSTs a real, decodable request of [chars] characters and returns the HTTP
/// status. A decodable body is the point: raw zeros would be refused by the
/// codec rather than by the size limit, which is a different path.
Future<int> _post(int port, int chars) async {
  final framed = RpcMessageFrame.encode(_codec.serialize(('x' * chars).rpc));
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/Svc/sink'),
    );
    request.headers.set('content-type', 'application/grpc');
    request.headers.contentLength = framed.length;
    request.add(framed);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  test(
    'a body inside the limit is delivered whole',
    () async {
      // The rewrite must not truncate or reorder: the handler sees every byte.
      const limit = 4 * 1024 * 1024;
      final rig = await _serve(limit: limit);

      expect(await _post(rig.port, 1024 * 1024), 200);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(rig.seen, [1024 * 1024]);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a body over the limit is refused, and the peer is answered',
    () async {
      // The overflow path keeps draining so the status can be flushed; bailing
      // out mid-body makes dart:io tear the connection down first, and the client
      // sees a socket error instead of a status.
      const limit = 512 * 1024;
      final rig = await _serve(limit: limit);

      final status = await _post(rig.port, limit + 64 * 1024);
      expect(status, isNot(200), reason: 'an oversized body must be refused');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(rig.seen, isEmpty, reason: 'the handler must never see it');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: the server still serves after refusing one',
    () async {
      // Load-bearing: an overflow must cost that request, not the connection
      // handling that follows it.
      const limit = 512 * 1024;
      final rig = await _serve(limit: limit);

      await _post(rig.port, limit + 64 * 1024);
      expect(await _post(rig.port, 4096), 200);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(rig.seen, [4096]);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
