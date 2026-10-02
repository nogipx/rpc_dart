// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server-stream call whose request stream ends without a single message,
// after a payload frame that decodes to none, must still be answered: it binds
// the responder and takes a handler slot, so silence holds the slot until the
// connection closes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Down',
      handler: (request, {RpcContext? context}) async* {
        yield request;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Opens [slots] server-stream calls that send [payload] (or nothing) and
/// half-close, then returns each call's grpc-status, or null if none came.
Future<void> _run(Uint8List? payload) async {
  const slots = 4;
  const policy = RpcSecurityPolicy(maxConcurrentHandlers: slots);
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final statuses = <Future<String?>>[];
  for (var i = 0; i < slots; i++) {
    final id = client.createStream();
    statuses.add(
      client
          .getMessagesForStream(id)
          .map((m) => m.metadata?.getHeaderValue('grpc-status'))
          .firstWhere((s) => s != null, orElse: () => null)
          .timeout(const Duration(seconds: 3), onTimeout: () => null),
    );
    await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'Down'));
    if (payload != null) await client.sendMessage(id, payload);
    await client.finishSending(id);
  }

  expect(
    await Future.wait(statuses),
    everyElement('${RpcStatus.invalidArgument}'),
    reason: 'a call with no request message must be refused, not left open',
  );
  final answer = await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'Echo',
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  expect(answer.value, 'x', reason: 'every handler slot must come back');
}

void main() {
  test('an empty DATA frame, then the half-close', () async {
    await _run(Uint8List(0));
  });

  test('control: no DATA frame at all', () async {
    await _run(null);
  });
}
