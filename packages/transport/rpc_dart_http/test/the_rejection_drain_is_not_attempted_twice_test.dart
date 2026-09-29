// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `Request.read()` may be called once per request — shelf throws
// `StateError: The 'read' method can only be called once` on a second call — and
// `_reject` drains the body before answering. The 408, 413 and 400 paths all reject
// a request whose body reader has already run, so that drain did nothing but throw
// into a silent catch.
//
// Harmless as behaviour: the peer still receives its 408, because the body is still
// attached when the response completes and dart:io detaches it then. So what is
// asserted here is not a status code — those are covered elsewhere — but that the
// transport no longer attempts an operation it knows will fail.
//
// The observable is the warning the narrowed catch now emits. Every other failure
// in that drain is the peer's doing; a StateError can only be ours, so it is the
// one error there that must not be swallowed.
//
// The control is a rejection BEFORE the body is read, where the drain is real and
// must still run — otherwise "no warning" is satisfied by removing the drain
// entirely, and an unread body makes dart:io tear the connection down before the
// status is flushed.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

typedef _Run = ({String peerSaw, int warnings});

/// Sends a request that promises a large body and delivers almost none.
///
/// [contentType] `null` omits the header, which is what the pre-read 415 rejection
/// needs; the gRPC content type is what gets a request as far as the body reader.
Future<_Run> _slowBody({String? contentType, bool completeBody = false}) async {
  final counter = _Counting();
  final transport = RpcHttpResponderTransport(
    bodyReadTimeout: const Duration(milliseconds: 400),
    logger: LogScope(counter, 'test'),
  );
  transport.incomingMessages.listen((_) {}, onError: (Object _) {});
  final http = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await http.close(force: true);
  });

  final socket = await Socket.connect('127.0.0.1', http.port);
  addTearDown(socket.destroy);
  final seen = Completer<String>();
  socket.listen(
    (bytes) {
      if (!seen.isCompleted) {
        seen.complete(String.fromCharCodes(bytes).split('\r\n').first);
      }
    },
    onError: (Object _) {
      if (!seen.isCompleted) seen.complete('socket error');
    },
    onDone: () {
      if (!seen.isCompleted) seen.complete('closed with nothing');
    },
  );
  socket.write(
    'POST /Svc/slow HTTP/1.1\r\n'
    'host: 127.0.0.1:${http.port}\r\n'
    '${contentType == null ? '' : 'content-type: $contentType\r\n'}'
    'content-length: ${completeBody ? 5 : 4000000}\r\n'
    '\r\n',
  );
  socket.add(const <int>[1, 2, 3, 4, 5]);
  await socket.flush();

  final peerSaw = await seen.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => 'NOTHING within 10s',
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return (peerSaw: peerSaw, warnings: counter.warnings);
}

void main() {
  test(
    'WITNESS: the 408 path does not attempt a drain that shelf refuses',
    () async {
      final run = await _slowBody(contentType: 'application/grpc+proto');

      expect(
        run.peerSaw,
        contains('408'),
        reason: 'the rig did not reach the body-read timeout at all',
      );
      expect(
        run.warnings,
        0,
        reason:
            'the drain was attempted after the body reader had run, so shelf threw '
            'StateError into a catch that said it was for a departed peer',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: a rejection BEFORE the body is read still drains, and its status still
  // reaches the peer. Without this, "no warning" is satisfied by deleting the drain
  // outright — and an unread body makes dart:io tear the connection down before the
  // status is flushed.
  //
  // The body here is COMPLETE, because that is the case the drain exists to serve.
  // A pre-read rejection of a body that never arrives is answered by a teardown
  // instead of a status, and deliberately so: the drain is deadlined, which is what
  // `a_refused_request_has_a_deadline_too_test` pins. Asserting a status there
  // would be asking for the thing that deadline gives up.
  test(
    'CONTROL: a pre-read rejection still answers its status',
    () async {
      final run = await _slowBody(
        contentType: 'text/plain',
        completeBody: true,
      );

      expect(
        run.peerSaw,
        contains('415'),
        reason:
            'the drain before a pre-read rejection is what lets the status reach '
            'the peer at all',
      );
      expect(run.warnings, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// Counts ONLY the drain's own warning.
///
/// Counting every warning would count the rejection's own log line — a 415 says so
/// out loud — and that is a legitimate record, not the thing under test. Done inside
/// the controller because a level guard cannot be observed from the record stream: a
/// filtered record is discarded either way.
class _Counting extends LogController {
  int warnings = 0;

  @override
  void add(LogRecord record) {
    if (record is LogEvent &&
        record.level == RpcLogLevel.warning &&
        record.message.contains('Rejection drain skipped')) {
      warnings++;
    }
    super.add(record);
  }
}
