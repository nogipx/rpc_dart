// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcMetadata.forClientRequest capped each name at 128 characters while the
// responder routes any path up to maxMethodPathLength (1024): a service name of
// 129 to ~1018 characters was registered, routable, and uncallable from this
// library. It also admitted a dot in the METHOD name, which the responder's
// grammar refuses because its binding key splits on the last dot.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Long extends RpcResponderContract {
  _Long(super.serviceName);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Get',
      handler: (req, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a service name the server routes is one the caller can call', () async {
    // A package-qualified name well past 128 and well inside 1024.
    final service = 'myapp.${'segment.' * 80}UserService';
    expect(service.length, greaterThan(128));

    final (client, server) = RpcChannelTransport.memoryPair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Long(service))
      ..start();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });

    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: service,
      methodName: 'Get',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(answer.value, 'ok');
  });

  test('a dotted method name is refused where the server would refuse it', () {
    expect(
      () => RpcMetadata.forClientRequest('Svc', 'Get.All'),
      throwsArgumentError,
    );
    expect(parseRpcMethodPath('/Svc/Get.All'), isNull);
  });

  test('CONTROL: a path past the default limit is still refused', () {
    final service = 'S' * kDefaultMaxMethodPathLength;
    expect(
      () => RpcMetadata.forClientRequest(service, 'Get'),
      throwsArgumentError,
    );
  });
}
