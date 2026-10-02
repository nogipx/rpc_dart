// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GUARD. A client-stream handler that stops reading -- `break` out of its
// `await for` -- while the client keeps uploading. The pipeline has an ERROR
// for a request frame with nowhere to go ("DROPPED"), and one for requests
// accepted but never delivered ("LOST"). Neither may fire here: the frames
// are still consumed below the handler, and a client that keeps sending after
// the server stopped listening is ordinary, so an error per frame would be a
// log flood any peer can cause. Measured clean; this pins it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _ReadsOne extends RpcResponderContract {
  _ReadsOne(this.released) : super('S');

  final Completer<void> released;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (requests, {RpcContext? context}) async {
        await for (final _ in requests) {
          break;
        }
        await released.future;
        return 'one'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('frames after the handler stopped reading log no warning', () async {
    final released = Completer<void>();
    final log = LogController(minLevel: RpcLogLevel.warning);
    final reported = <String>[];
    log.stream.listen((r) {
      if (r is LogEvent) reported.add(r.message);
    });
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server)
      ..setLogController(log)
      ..registerServiceContract(_ReadsOne(released))
      ..start();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });

    final requests = StreamController<RpcString>();
    final call = caller.clientStream<RpcString, RpcString>(
      serviceName: 'S',
      methodName: 'c',
      requestCodec: _codec,
      responseCodec: _codec,
    )(requests.stream);
    for (var i = 0; i < 20; i++) {
      requests.add('$i'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await requests.close();
    released.complete();

    expect((await call).value, 'one');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reported, isEmpty);
  });
}
