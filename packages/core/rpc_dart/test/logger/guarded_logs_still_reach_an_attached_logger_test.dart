// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `if (_logger.isInternal)` must be a performance guard, not a mute button.
//
// Rounds 333-334 wrapped the unary per-call sites, because `internal` takes a
// String and so builds it even when the logger is `LogScope.noop`. Round 337
// swept the rest: 158 interpolating sites across core, the framework and the
// two HTTP transports.
//
// The risk of that change is silent: if a guard reads a level the logger does
// not actually apply, the messages vanish for everyone and no existing test
// notices, because nothing else asserts that these particular lines are
// emitted. This is that assertion, and it names at least one line per guarded
// FILE -- a guard is only watched where a test names a line behind it.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'serverStream',
      handler: (r, {RpcContext? context}) async* {
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'clientStream',
      handler: (requests, {RpcContext? context}) async {
        await requests.drain<void>();
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late LogController controller;
  late List<String> seen;
  late StreamSubscription<Object> sub;
  late RpcChannelTransport clientT;
  late RpcChannelTransport serverT;
  late RpcResponderEndpoint responder;
  late RpcCallerEndpoint caller;

  setUp(() {
    controller = LogController(minLevel: RpcLogLevel.internal);
    seen = <String>[];
    sub = controller.stream.listen((record) {
      if (record is LogEvent) seen.add(record.message);
    });

    final pair = RpcChannelTransport.pair();
    clientT = pair.$1;
    serverT = pair.$2;
    responder = RpcResponderEndpoint(transport: serverT, logger: controller)
      ..registerServiceContract(_Svc())
      ..start();
    caller = RpcCallerEndpoint(transport: clientT, logger: controller);
  });

  tearDown(() async {
    await sub.cancel();
    await caller.close();
    await responder.close();
    await clientT.close();
    await serverT.close();
    controller.dispose();
  });

  void expectLine(String prefix, String file) => expect(
    seen.any((m) => m.startsWith(prefix)),
    isTrue,
    reason: '$file was muted: no line starting with "$prefix"',
  );

  test(
    'a unary call still logs at internal level when one is attached',
    () async {
      final reply = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'hi'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(reply.value, 'hi');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Three phases of the responder's request handling. Ablate any guard to
      // `if (false)` and the matching row disappears while the call still
      // succeeds -- which is exactly the failure this test exists to make loud.
      expectLine('Handling request for /Svc/echo', 'unary/responder.dart');
      expectLine('Serializing response', 'unary/responder.dart');
      expectLine('Sending success trailer', 'unary/responder.dart');

      // Round 334 guarded the caller and the frame parser too.
      expectLine('Unary call /Svc/echo started', 'unary/caller.dart');
      expectLine('Serializing request', 'unary/caller.dart');
      expectLine('Chunk processed, messages extracted', 'core/parser.dart');

      // The endpoint layer, guarded in round 337.
      expectLine('Registering service contract', 'responder_registry.dart');
      expectLine('Metadata received [method:', 'responder_pipeline.dart');
    },
  );

  test('the three streaming shapes still log at internal level', () async {
    await caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'serverStream',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();

    await caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'clientStream',
      requestCodec: _codec,
      responseCodec: _codec,
    )(Stream.fromIterable(['a'.rpc]));

    await caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'bidi',
          requests: Stream.fromIterable(['a'.rpc]),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();

    await Future<void>.delayed(const Duration(milliseconds: 100));

    // One line per file round 337 guarded on these paths. The streaming shapes
    // carried 42/36/28 discarded messages per round trip against unary's 6 --
    // they are where the volume was, and before this round not one of their
    // guards existed, so not one of them was watched.
    expectLine('Creating Serialized ServerStreamResponder', 'server/responder');
    expectLine('Invoking request handler', 'server/responder.dart');
    expectLine('Creating Serialized ServerStreamCaller', 'server/caller.dart');
    expectLine('Creating Serialized ClientStreamResponder', 'client/responder');
    expectLine('Sending request to client stream', 'client/caller.dart');
    expectLine('Creating Serialized BidirectionalStreamResponder', 'bidi/resp');
    expectLine('Creating Serialized BidirectionalStreamCaller', 'bidi/caller');

    // The shared processor both halves run on: 30 of the 158 sites.
    expectLine('Stream bound [methodPath:', 'base_processor.dart');
    expectLine('Sending request for /Svc/', 'base_processor.dart');
    expectLine('Response stream completed for /Svc/', 'base_processor.dart');
  });

  test('the endpoint lifecycle paths still log at internal level', () async {
    caller.addMiddleware(const _NoopMiddleware());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expectLine('Middleware added:', 'base_endpoint.dart');
  });
}

final class _NoopMiddleware extends IRpcMiddleware {
  const _NoopMiddleware();
}
