// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Support script for test/audit/detached_guard_has_a_witness_test.dart.
//
// Whether this process exits 0 is the measurement, so it runs in a SUBPROCESS:
// the failure being guarded against is the root zone killing the isolate, and
// nothing inside that isolate can assert it did not die. There is deliberately
// no exit() call, no zone guard and no watchdog Timer -- a runZonedGuarded here
// would BE the missing guard and every arm would pass.
//
// argv[0]:
//   throw  - the handler raises mid-call. `responder.done` then completes with
//            that error, and the seven
//            `_detached(responder.done.whenComplete(...))` sites hand it to
//            `_detached` -- `whenComplete` propagates its receiver's error.
//   cancel - the client hangs up mid-call. Recorded because it is the shape the
//            production incident describes, and it does NOT reach the guard:
//            `_handleClientCancellation` only calls `_closeResponder` and
//            `_cleanupStream`, and both catch their own user code.
//   clean  - CONTROL: the same call, ended normally. Proves the harness exits 0
//            on its own, so a non-zero exit elsewhere is the scenario.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.mode) : super('Svc');

  final String mode;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chat',
      requestCodec: _codec,
      responseCodec: _codec,
      // No try, no onError. That is the production shape, not an oversight:
      // an aborted handler raises, which is the incident _detached was written
      // for ("both replicas exited 255 within hours of each other").
      handler: (requests, {context}) async* {
        await for (final r in requests) {
          if (mode == 'throw') {
            throw StateError('handler aborted while serving the call');
          }
          yield r;
        }
      },
    );
  }
}

Future<void> main(List<String> argv) async {
  final mode = argv.isEmpty ? 'throw' : argv.first;

  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc(mode));
  responder.start();

  final id = client.createStream();
  client.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'chat'));
  await client.sendMessage(
    id,
    RpcMessageFrame.encode(_codec.serialize('hi'.rpc)),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));

  if (mode == 'cancel') {
    // Byte for byte what base_processor.dart sends when a caller cancels: bare
    // metadata, no methodPath, x-client-cancelled true.
    await client.sendMetadata(
      id,
      RpcMetadata([
        RpcHeader(RpcHeaders.xClientCancelled, 'true'),
        RpcHeader(RpcHeaders.xCancellationReason, 'client hung up'),
        RpcHeader(RpcHeaders.grpcStatus, RpcStatus.cancelled.toString()),
      ]),
      endStream: true,
    );
  } else {
    await client.finishSending(id);
  }

  await Future<void>.delayed(const Duration(milliseconds: 600));
  await responder.close();
  await client.close();
}
