// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcChannelTransport routes every inbound frame to BOTH the per-stream
// controller and the global _incoming BufferedBroadcastController. That
// controller buffers while it has no listener, so the responder pipeline does
// not miss frames arriving before it subscribes.
//
// A caller-only endpoint never subscribed to it at all -- it reads responses
// through getMessagesForStream -- so on a pure client nothing ever drained the
// buffer:
//
//   300 unary calls on a caller-only endpoint
//     messages retained by the client transport : 900
//
// Three frames per call (initial metadata, payload, trailer), held for the life
// of the connection, each pinning its payload, until the 4096-event cap.
//
// The same gap swallowed transport-level errors. A frame that violates the
// security policy but belongs to no known stream is reported ONLY on
// incomingMessages, so a pure client never saw one at all.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Counts what a late subscriber receives — i.e. what the buffer had retained.
Future<int> _replayed(RpcChannelTransport transport) async {
  var seen = 0;
  final sub = transport.incomingMessages.listen(
    (_) => seen++,
    onError: (Object _) {},
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await sub.cancel();
  return seen;
}

void main() {
  test('a caller-only endpoint does not retain inbound frames', () async {
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();

    for (var i = 0; i < 100; i++) {
      await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
    }

    final retained = await _replayed(client);
    expect(
      retained,
      0,
      reason: '$retained frames were still buffered on the client transport',
    );

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('a caller surfaces transport-level errors', () async {
    final logs = RingBufferOutput();
    final controller = LogController(outputs: [logs]);

    // Asymmetric policies: the sender may emit a frame its peer must refuse,
    // so the violation is detected on the RECEIVE path where only the global
    // stream reports it.
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
    final client = RpcChannelTransport(
      channel: clientCh,
      isClient: true,
      // No stream is open for this id, so the error has nowhere to go but the
      // global stream.
      policy: const RpcSecurityPolicy(maxHeaders: 2),
    );
    final server = RpcChannelTransport(
      channel: serverCh,
      isClient: false,
      policy: const RpcSecurityPolicy(maxHeaders: 64),
    );
    final caller = RpcCallerEndpoint(transport: client, logger: controller);

    await server.sendMetadata(
      2,
      RpcMetadata([for (var i = 0; i < 8; i++) RpcHeader('h-$i', 'v')]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final errors = logs.entries
        .whereType<LogEvent>()
        .where((e) => e.level == RpcLogLevel.error)
        .toList();
    expect(
      errors,
      isNotEmpty,
      reason: 'the client silently discarded a transport-level error',
    );
    expect(errors.first.message, contains('Transport incoming error'));

    await caller.close();
    await client.close();
    await server.close();
    controller.dispose();
  });

  test('draining does not steal frames from the responder', () async {
    // The cheap wrong fix is a drain that consumes what other consumers need.
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();

    final results = await Future.wait([
      for (var i = 0; i < 5; i++)
        caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'v$i'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
    ]);
    expect(results.map((r) => r.value), ['v0', 'v1', 'v2', 'v3', 'v4']);

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('closing the caller detaches its observer', () async {
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);

    await caller.close();
    expect(caller.isActive, isFalse);

    // Closing twice must stay safe.
    await caller.close();

    await client.close();
    await server.close();
  });
}
