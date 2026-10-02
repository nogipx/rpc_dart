// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A contract unregistered while one of its client-stream calls is running.
// The call's later frames looked the method up again and found nothing: the
// handler's request stream ended clean on the messages it had, and it
// committed them, while the peer was told UNIMPLEMENTED -- two different
// answers for one call. Now the running call keeps its method; new calls are
// refused.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Upload extends RpcResponderContract {
  _Upload(this.committed) : super('U');

  final List<int> committed;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      handler: (requests, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
        }
        committed.add(n);
        return 'n=$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'unregistering mid-call: the call finishes, a new one is refused',
    () async {
      final committed = <int>[];
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Upload(committed))
        ..start();
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final requests = StreamController<RpcString>();
      final running = caller.clientStream<RpcString, RpcString>(
        serviceName: 'U',
        methodName: 'upload',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);
      requests
        ..add('1'.rpc)
        ..add('2'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      responder.unregisterServiceContract('U');
      requests
        ..add('3'.rpc)
        ..add('4'.rpc);
      await requests.close();

      expect((await running).value, 'n=4');
      expect(committed, [4]);

      await expectLater(
        caller.clientStream<RpcString, RpcString>(
          serviceName: 'U',
          methodName: 'upload',
          requestCodec: _codec,
          responseCodec: _codec,
        )(Stream.value('x'.rpc)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'status',
            RpcStatus.unimplemented,
          ),
        ),
      );
    },
  );
}
