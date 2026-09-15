// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream handler must see every request the caller sent, and the
// pipeline must never drop one in silence.
//
// A consumer measured both ends of the same upload and found them disagreeing:
// the caller handed 17 messages to `send()` and the handler was given 16, with
// no error on either side and a successful response. A request that is dropped
// without a word is the worst failure this pipeline has — the peer is told the
// call succeeded over data the handler never saw.
//
// The buffering decision is where it can happen. A payload for a client-stream
// is buffered while there is nowhere to put it and replayed when the responder
// binds; the condition for "nowhere to put it" was `!_boundToMessageStream`,
// while the delivery condition is `hasRequestSink`. They are NOT the same
// question — `detachRequestSink()` clears the sink and leaves the flag set — so
// a message arriving in between is neither buffered nor delivered.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Records what the handler was actually given.
final class _CollectingContract extends RpcResponderContract {
  _CollectingContract() : super('Svc');

  final seen = <String>[];

  /// Held until released, so the handler can be made to subscribe LATE — the
  /// shape an interceptor chain produces in front of a real handler.
  Completer<void>? gate;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      handler: (requests, {RpcContext? context}) async {
        final g = gate;
        if (g != null) await g.future;
        await for (final r in requests) {
          seen.add(r.value);
        }
        return RpcString('${seen.length}');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcChannelTransport client;
  late RpcChannelTransport server;
  late RpcResponderEndpoint responder;
  late RpcCallerEndpoint caller;
  late _CollectingContract service;

  setUp(() {
    final pair = RpcChannelTransport.pair();
    client = pair.$1;
    server = pair.$2;
    service = _CollectingContract();
    responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(service);
    responder.start();
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  Future<String> collect(Stream<RpcString> requests) => caller
      .clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Collect',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests)
      .timeout(const Duration(seconds: 20))
      .then((r) => r.value);

  test('every request reaches the handler when it subscribes late', () async {
    // The handler is held before its first `await for`, which is what an
    // interceptor chain does in front of it. Messages arriving in that window
    // have a bound responder and no sink yet.
    service.gate = Completer<void>();
    final requests = StreamController<RpcString>();
    final answer = collect(requests.stream);

    for (var i = 0; i < 8; i++) {
      requests.add(RpcString('m$i'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.gate!.complete();
    await requests.close();

    expect(await answer, '8');
    expect(service.seen, [for (var i = 0; i < 8; i++) 'm$i']);
  });

  test('a message produced after the generator suspends is not lost', () async {
    // The field client encrypts a whole blob between messages, so the stream
    // goes quiet for a while and then resumes. Every message must still land.
    Stream<RpcString> suspending() async* {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        yield RpcString('m$i');
      }
    }

    expect(await collect(suspending()), '6');
    expect(service.seen, [for (var i = 0; i < 6; i++) 'm$i']);
  });

  test('large messages are not dropped at the call opening', () async {
    // The opening message is the only one that shares its delivery with the
    // frame that opens the call, and in the field it is ~1 MB.
    final big = 'x' * (900 * 1024);
    final requests = StreamController<RpcString>();
    final answer = collect(requests.stream);
    for (var i = 0; i < 4; i++) {
      requests.add(RpcString('m$i$big'));
    }
    await requests.close();

    expect(await answer, '4');
    expect(service.seen.map((s) => s.substring(0, 2)), [
      'm0',
      'm1',
      'm2',
      'm3',
    ]);
  });
}
