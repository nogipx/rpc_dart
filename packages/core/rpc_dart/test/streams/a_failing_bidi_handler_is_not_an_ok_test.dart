// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi handler whose response stream fails part-way must end the call with
// that failure. A half-close after the messages that did arrive would read to
// the client as a complete answer: a silent short read.
//
// The last test drives the responder class directly, because what it checks
// is the responder's own teardown.

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Two messages and then a failure, from a source that ends at its throw.
Stream<RpcString> _twoThenError() async* {
  yield 'x'.rpc;
  yield 'y'.rpc;
  throw StateError('handler source died');
}

Stream<RpcString> _twoClean() async* {
  yield 'x'.rpc;
  yield 'y'.rpc;
}

/// Two messages and then an explicit status.
Stream<RpcString> _twoThenStatus() async* {
  yield 'x'.rpc;
  yield 'y'.rpc;
  throw RpcStatusException(RpcStatus.notFound, 'no such item');
}

final class _Contract extends RpcResponderContract {
  _Contract() : super('S');

  @override
  void setup() {
    for (final (name, source) in [
      ('fails', _twoThenError),
      ('clean', _twoClean),
      ('status', _twoThenStatus),
    ]) {
      addBidirectionalMethod<RpcString, RpcString>(
        methodName: name,
        handler: (requests, {RpcContext? context}) => source(),
        requestCodec: _codec,
        responseCodec: _codec,
      );
    }
  }
}

/// What the CLIENT ends up believing about a call to [method]: the payloads,
/// and how the call ended. An OVERALL deadline, not a per-event one: the
/// question is how the call ends, and "it never ends" is one of the answers.
Future<String> _asClientSeesIt(String method) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  final got = <String>[];
  final done = Completer<String>();

  void finish(String how) {
    if (!done.isCompleted) done.complete('${got.length} payloads, $how');
  }

  caller
      .bidirectionalStream<RpcString, RpcString>(
        serviceName: 'S',
        methodName: method,
        requests: Stream.value('start'.rpc),
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen(
        (v) => got.add(v.value),
        onDone: () => finish('ended OK'),
        onError: (Object e) => finish(
          e is RpcStatusException
              ? 'status ${e.statusCode}'
              : '${e.runtimeType}',
        ),
      );
  Timer(const Duration(seconds: 3), () => finish('NEVER ENDED'));
  return done.future;
}

void main() {
  group('a bidi handler whose response stream fails', () {
    test('WITNESS: the client is not told OK', () async {
      expect(
        await _asClientSeesIt('fails'),
        '2 payloads, status ${RpcStatus.internal}',
        reason:
            'the handler\'s source failed after 2 of its messages; the client '
            'must be told, not left waiting',
      );
    });

    test('GUARD: a handler that finishes cleanly still ends OK', () async {
      expect(await _asClientSeesIt('clean'), '2 payloads, ended OK');
    });

    test('GUARD: an explicit status still reaches the client', () async {
      expect(
        await _asClientSeesIt('status'),
        '2 payloads, status ${RpcStatus.notFound}',
      );
    });
  });

  group('the responder class', () {
    test(
      'WITNESS: close() returns with the handler parked on an await',
      () async {
        // Awaiting the cancel of an `async*` suspended at an `await` never
        // returns, because the VM's cancellation future completes only when the
        // generator body does.
        final (client, server) = RpcChannelTransport.memoryPair();
        final responder = BidirectionalStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: server,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: _codec,
          responseCodec: _codec,
          handler: (requests) async* {
            yield 'x'.rpc;
            await Completer<void>().future;
          },
        );
        responder.bindToMessageStream(
          server.incomingMessages.where((m) => m.streamId == 1),
        );
        final caller = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: _codec,
          responseCodec: _codec,
        );
        caller.responses.listen((_) {}, onError: (Object _) {});

        await caller.send('start'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await expectLater(
          responder.close().timeout(const Duration(seconds: 5)),
          completes,
          reason: 'close() awaited a cancel a parked generator never completes',
        );

        await caller.close().catchError((_) {});
        await client.close();
        await server.close();
      },
    );
  });
}
