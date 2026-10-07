// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The host's connection flow-control window reaches the worker.
//
// The host transport advertises it from its constructor, before the worker
// script has necessarily run, so the grant is the first message the worker is
// sent. Lost, the worker's connection credit stays null -- unbounded -- and
// host-to-worker flow control is silently off.

@TestOn('browser')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

void _unusedEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {}

void main() {
  test(
    'the worker holds the host\'s connection window',
    () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: _unusedEntrypoint,
        workerUri: Uri.base.resolve('echo_worker.dart.js'),
      );
      final caller = RpcCallerEndpoint(transport: spawned.transport);
      addTearDown(() async {
        await caller.close();
        spawned.kill();
      });

      final credit = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'EchoService',
            methodName: 'Credit',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: ''.rpc,
          )
          .timeout(const Duration(seconds: 15));

      expect(credit.value, isNot('null'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
