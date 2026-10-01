// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `close()` closes the http client it owns, so every request parked at that moment
// fails with a `ClientException` and lands in `_fireRequest`'s catch. At `error`
// that is one record per in-flight call for an orderly shutdown.
//
// The branch immediately above that catch is both the control and the model: an
// abandoned call is logged at `internal`, because "logging it at error would make
// every ordinary cancellation look like a failure". A close is the same event with
// a different trigger.
//
// The count must scale with the calls, which is why there are two arms: one error
// would be a message, N errors is the defect.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Counts records by level, with `internal` admitted so a zero at `error` can be
/// told from a log that was deleted rather than moved.
class _Counting extends LogController {
  _Counting() : super(minLevel: RpcLogLevel.internal);

  int errors = 0;
  int internals = 0;

  @override
  void add(LogRecord record) {
    if (record is! LogEvent) return;
    if (record.level == RpcLogLevel.error) errors++;
    if (record.level == RpcLogLevel.internal) internals++;
  }
}

/// Parks [calls] requests at a server that never answers, then closes the
/// transport under them.
Future<_Counting> _closeUnder({required int calls}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.forEach((request) async {
    await request.drain<void>();
    // Never answered: the request is still in flight when close() lands.
  }).ignore();

  final counter = _Counting();
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
    logger: LogScope(counter, 'test'),
  );
  addTearDown(() async {
    await transport.close();
    await server.close(force: true);
  });

  for (var i = 0; i < calls; i++) {
    final streamId = transport.createStream();
    final sub = transport
        .getMessagesForStream(streamId)
        .listen((_) {}, onError: (Object _) {});
    addTearDown(sub.cancel);
    await transport.sendMetadata(
      streamId,
      RpcMetadata.forClientRequest('Svc', 'echo'),
    );
    await transport.sendMessage(
      streamId,
      RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
    );
    unawaited(transport.finishSending(streamId));
  }

  // Let every request reach the server and park.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  expect(counter.errors, 0, reason: 'nothing has failed yet');

  await transport.close();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return counter;
}

void main() {
  test('WITNESS closing under 8 calls logs no error at all', () async {
    final counter = await _closeUnder(calls: 8);

    expect(
      counter.errors,
      0,
      reason: 'an orderly shutdown is not eight failures',
    );
    expect(
      counter.internals,
      greaterThan(0),
      reason: 'the event is still recorded, one level down — not deleted',
    );
  });

  test('CONTROL one call, so the count is known to scale', () async {
    final counter = await _closeUnder(calls: 1);

    expect(counter.errors, 0);
  });

  test('GUARD a real failure is still an error', () async {
    // Load-bearing: the fix keys off `_isClosed`, so a failure with the transport
    // OPEN must still read as one. Nothing is listening on port 1.
    final counter = _Counting();
    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:1',
      logger: LogScope(counter, 'test'),
    );
    addTearDown(transport.close);

    final streamId = transport.createStream();
    final ended = Completer<void>();
    final sub = transport
        .getMessagesForStream(streamId)
        .listen(
          (message) {
            if (message.isEndOfStream && !ended.isCompleted) ended.complete();
          },
          onError: (Object _) {
            if (!ended.isCompleted) ended.complete();
          },
        );
    addTearDown(sub.cancel);

    await transport.sendMetadata(
      streamId,
      RpcMetadata.forClientRequest('Svc', 'echo'),
    );
    await transport.sendMessage(
      streamId,
      RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
    );
    await transport.finishSending(streamId);
    await ended.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('the call never ended'),
    );

    expect(
      counter.errors,
      greaterThan(0),
      reason: 'a refused connection is a real failure and must say so',
    );
  });
}
