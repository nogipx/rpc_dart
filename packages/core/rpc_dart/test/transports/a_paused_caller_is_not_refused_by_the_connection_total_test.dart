// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A sender may admit one message on its last byte of connection credit, so an
// honest peer can have the connection window plus one message outstanding.
// The receiver bounded the connection total at the window alone, and a caller
// that paused its server streams and resumed them had one failed with
// RESOURCE_EXHAUSTED "past the connection total".

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
final _go = Completer<void>();

final class _Feed extends RpcResponderContract {
  _Feed() : super('Feed');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'feed',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        await _go.future;
        final body = 'x' * 40000;
        for (var i = 0; i < 20; i++) {
          yield body.rpc;
        }
      },
    );
  }
}

void main() {
  test('WITNESS paused and resumed streams are not refused', () async {
    final (client, server) = RpcChannelTransport.pair(
      policy: const RpcSecurityPolicy(
        flowControlConnectionWindowBytes: 64 * 1024,
      ),
    );
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Feed())
      ..start();
    final caller = RpcCallerEndpoint(transport: client)..start();
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });

    final errors = <Object>[];
    var received = 0;
    final done = <Future<void>>[];
    final subs = <StreamSubscription<RpcString>>[];
    for (var i = 0; i < 4; i++) {
      final finished = Completer<void>();
      done.add(finished.future);
      subs.add(
        caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Feed',
              methodName: 'feed',
              requestCodec: _codec,
              responseCodec: _codec,
              request: ''.rpc,
            )
            .listen(
              (_) => received++,
              onError: errors.add,
              onDone: finished.complete,
            ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final sub in subs) {
      sub.pause();
    }
    _go.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final sub in subs) {
      sub.resume();
    }
    await Future.wait(done).timeout(const Duration(seconds: 20));

    expect(errors, isEmpty, reason: 'an honest caller was refused');
    expect(received, 80);
  });
}
