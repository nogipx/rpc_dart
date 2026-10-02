// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `requestSink.addStream(source)` where the source emits an error and stays
// open -- a StreamController, a shared feed. An `async*` ends at its error, so
// it never showed this. The call fails at the error; after that the source
// must be let go: its addStream completes, nothing more is sent, and closing
// the caller works and frees the stream.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo(this.got) : super('Svc');

  final List<String> got;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          got.add(r.value);
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a source that errs and stays open is let go', () async {
    final got = <String>[];
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Echo(got))
      ..start();
    addTearDown(() async {
      await responder.close();
      await client.close();
      await server.close();
    });
    final caller = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    caller.responses.listen((_) {}, onError: (Object _) {});

    var sourceCancelled = false;
    final source = StreamController<RpcString>(
      onCancel: () => sourceCancelled = true,
    );
    final addStream = caller.requestSink.addStream(source.stream);
    source.add('a'.rpc);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    source.addError(StateError('transient'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    source.add('after'.rpc);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sourceCancelled, isTrue, reason: 'the source is still pulled');
    await addStream.timeout(const Duration(seconds: 2));
    expect(got, ['a'], reason: 'nothing goes out after the failure');

    await caller.close();
    final health = await client.health();
    expect(health.details['activeStreams'], 0);
    expect(health.details['streamControllers'], 0);
  });
}
