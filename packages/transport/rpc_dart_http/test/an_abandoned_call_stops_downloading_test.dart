// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `releaseStreamId` freed bookkeeping and nothing else: the POST and the body read
// carried on to the end, so a cancelled or timed-out call kept its socket and its
// bandwidth until the server finished. The `maxActiveStreams` slot is returned at
// the same moment, so the ceiling stops bounding real sockets exactly when it
// matters most.
//
// Measured at the SERVER, because that is the only side that can say whether the
// download really ended — an abandoned future looks identical either way from the
// client. The server streams a long response slowly and records how far it got.
//
// The guard is the one that keeps the fix from being worse than the defect: an
// abort is this side's own doing, so it must reach the endpoint as NOTHING. Turning
// every cancellation into a reported transport failure would answer a stream
// nobody is listening to and make ordinary teardown look like breakage.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

const _chunks = 40;
const _perChunk = Duration(milliseconds: 50);

typedef _Run = ({int written, bool finished, int errors});

/// A server that streams a long response slowly and records how far it got.
class _Streamer {
  _Streamer(this._http);

  final HttpServer _http;
  int chunksWritten = 0;
  bool finished = false;

  static Future<_Streamer> start() async {
    final http = await HttpServer.bind('127.0.0.1', 0);
    final s = _Streamer(http);
    http.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType = ContentType(
        'application',
        'grpc+proto',
      );
      try {
        for (var i = 0; i < _chunks; i++) {
          req.response.add(List<int>.filled(1024, 0));
          await req.response.flush();
          s.chunksWritten++;
          await Future<void>.delayed(_perChunk);
        }
        s.finished = true;
        await req.response.close();
      } catch (_) {
        // The client went away. That is the outcome being measured.
      }
    });
    return s;
  }

  int get port => _http.port;

  Future<void> stop() => _http.close(force: true);
}

Future<_Run> _run({required bool abandon}) async {
  final server = await _Streamer.start();
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  var errors = 0;
  transport.incomingMessages.listen((_) {}, onError: (Object _) => errors++);
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await server.stop();
  });

  final id = transport.createStream();
  await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'slow'));
  // Not awaited: it completes only when the whole body is read, which is the
  // thing under test.
  unawaited(
    transport
        .sendMessage(
          id,
          RpcMessageFrame.encode(Uint8List.fromList(<int>[1, 2, 3])),
          endStream: true,
        )
        .catchError((Object _) {}),
  );

  // Long enough that the response is demonstrably in progress.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  if (abandon) transport.releaseStreamId(id);

  // Past the point where an unabandoned response would have finished.
  await Future<void>.delayed(_perChunk * (_chunks + 6));

  return (
    written: server.chunksWritten,
    finished: server.finished,
    errors: errors,
  );
}

void main() {
  test(
    'WITNESS: abandoning a call stops the download at the server',
    () async {
      final run = await _run(abandon: true);

      expect(
        run.finished,
        isFalse,
        reason:
            'the server wrote its whole response to a client that had already '
            'given up: the socket and the bandwidth are held until the server '
            'stops, and the concurrency slot is already back',
      );
      expect(run.written, lessThan(_chunks));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: a call nobody abandons must still complete. Without this, "the
  // server did not finish" is equally consistent with a transport that broke the
  // request outright.
  test(
    'CONTROL: a call left alone runs to completion',
    () async {
      final run = await _run(abandon: false);

      expect(run.finished, isTrue);
      expect(run.written, _chunks);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: an abort is this side's own doing, so nothing may be reported for it.
  // A cancellation that surfaced as a transport error would answer a stream the
  // endpoint has stopped listening to.
  test(
    'GUARD: an abandoned call reports no error',
    () async {
      final run = await _run(abandon: true);

      expect(
        run.errors,
        0,
        reason: 'ordinary teardown now looks like a transport failure',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
