// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A client-stream handler must observe each request exactly once.
///
/// The responder pipeline buffers client-stream payloads itself
/// (`_clientBufferedMessages`) and replays them at bind time, while
/// [RpcChannelTransport] ALSO keeps a per-stream single-subscription
/// controller that buffers until its consumer subscribes. If both buffers hold
/// the same frames, the handler sees every message twice.
void main() {
  group('client stream delivery', () {
    test('frame transport: each request delivered exactly once', () async {
      final (clientTransport, serverTransport) = RpcChannelTransport.pair();

      final service = _CountingContract();
      final responder = RpcResponderEndpoint(transport: serverTransport);
      responder.registerServiceContract(service);
      responder.start();

      final caller = RpcCallerEndpoint(transport: clientTransport);

      final requests = StreamController<RpcString>();
      final responseFuture = caller.clientStream<RpcString, RpcString>(
        serviceName: 'Counting',
        methodName: 'Collect',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      )(requests.stream);

      for (var i = 0; i < 5; i++) {
        requests.add('chunk-$i'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await requests.close();

      await responseFuture;

      expect(
        service.received,
        equals(['chunk-0', 'chunk-1', 'chunk-2', 'chunk-3', 'chunk-4']),
        reason: 'handler saw duplicates: ${service.received}',
      );

      await caller.close();
      await responder.close();
    });

    test(
      'frame transport: burst without gaps delivered exactly once',
      () async {
        final (clientTransport, serverTransport) = RpcChannelTransport.pair();

        final service = _CountingContract();
        final responder = RpcResponderEndpoint(transport: serverTransport);
        responder.registerServiceContract(service);
        responder.start();

        final caller = RpcCallerEndpoint(transport: clientTransport);

        final requests = StreamController<RpcString>();
        final responseFuture = caller.clientStream<RpcString, RpcString>(
          serviceName: 'Counting',
          methodName: 'Collect',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
        )(requests.stream);

        // No delay between sends: everything lands before the responder binds.
        for (var i = 0; i < 5; i++) {
          requests.add('chunk-$i'.rpc);
        }
        await requests.close();

        await responseFuture;

        expect(
          service.received,
          equals(['chunk-0', 'chunk-1', 'chunk-2', 'chunk-3', 'chunk-4']),
          reason: 'handler saw duplicates: ${service.received}',
        );

        await caller.close();
        await responder.close();
      },
    );
  });
}

final class _CountingContract extends RpcResponderContract {
  _CountingContract() : super('Counting');

  final List<String> received = [];

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      handler: _collect,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _collect(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async {
    await for (final r in requests) {
      received.add(r.value);
    }
    return 'ok'.rpc;
  }
}
