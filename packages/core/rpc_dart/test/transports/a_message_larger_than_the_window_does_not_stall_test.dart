// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A message is admitted while any credit remains, so one larger than the
// per-stream window leaves the sender's credit below zero, and the receiver
// returns all of it in one grant. That grant was capped at the window before
// it was added, so the difference was lost and the stream stopped for good:
// under the default policy (4 MiB window, 16 MiB messages) a server stream of
// 7 MB messages delivered two and hung.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Feed extends RpcResponderContract {
  _Feed(this.count, this.size) : super('Feed');

  final int count;
  final int size;

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'feed',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        final body = 'x' * size;
        for (var i = 0; i < count; i++) {
          yield body.rpc;
        }
      },
    );
  }
}

Future<int> _receive({required int count, required int size}) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Feed(count, size))
    ..start();
  final caller = RpcCallerEndpoint(transport: client)..start();
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  var received = 0;
  await caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Feed',
        methodName: 'feed',
        requestCodec: _codec,
        responseCodec: _codec,
        request: ''.rpc,
      )
      .forEach((_) => received++)
      .timeout(const Duration(seconds: 20), onTimeout: () {});
  return received;
}

void main() {
  test(
    'WITNESS messages larger than the default window all arrive',
    () async {
      expect(
        await _receive(count: 3, size: 7 * 1000 * 1000),
        3,
        reason: 'the stream stalled once a grant was cut to the window',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('messages within the window are unaffected', () async {
    expect(await _receive(count: 50, size: 64 * 1024), 50);
  });
}
