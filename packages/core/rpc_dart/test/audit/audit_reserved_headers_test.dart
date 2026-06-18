// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// User-supplied metadata must not override protocol-reserved headers
/// (content-type, te, grpc-encoding, grpc-timeout, ...), or it would corrupt
/// framing/compression/status negotiation. The client strips them.
void main() {
  group('reserved headers', () {
    test('isReserved recognises protocol headers (case-insensitive)', () {
      expect(RpcHeaders.isReserved('content-type'), isTrue);
      expect(RpcHeaders.isReserved('Content-Type'), isTrue);
      expect(RpcHeaders.isReserved('grpc-timeout'), isTrue);
      expect(RpcHeaders.isReserved('te'), isTrue);
      expect(RpcHeaders.isReserved('user-agent'), isTrue);
      // Compression headers are framework-routed through context, not reserved.
      expect(RpcHeaders.isReserved('grpc-encoding'), isFalse);
      expect(RpcHeaders.isReserved('grpc-accept-encoding'), isFalse);
      expect(RpcHeaders.isReserved('x-custom'), isFalse);
      expect(RpcHeaders.isReserved('authorization'), isFalse);
    });

    test('client strips reserved headers from user metadata', () async {
      final (clientT, serverT) = RpcChannelTransport.memoryPair();
      final server = RpcResponderEndpoint(transport: serverT);
      final client = RpcCallerEndpoint(transport: clientT);

      final seen = Completer<RpcMetadata>();
      serverT.incomingMessages.listen((m) {
        if (m.metadata != null && !seen.isCompleted) {
          seen.complete(m.metadata);
        }
      });
      server.registerServiceContract(_EchoContract());
      server.start();

      // A user tries to override content-type and te, plus a legitimate
      // custom header that must survive.
      final ctx = RpcContext.withHeaders({
        'content-type': 'text/evil',
        'te': 'chunked',
        'x-custom': 'keep-me',
      });
      await client.unaryRequest<_Msg, _Msg>(
        serviceName: 'S',
        methodName: 'echo',
        request: const _Msg('hi'),
        requestCodec: _Msg.codec,
        responseCodec: _Msg.codec,
        context: ctx,
      );

      final md = await seen.future.timeout(const Duration(seconds: 2));
      expect(md.getHeaderValue('content-type'), isNot('text/evil'));
      expect(md.getHeaderValue('te'), isNot('chunked'));
      expect(md.getHeaderValue('x-custom'), 'keep-me');

      await client.close();
      await server.close();
    });
  });
}

final class _Msg implements IRpcSerializable {
  final String value;
  const _Msg(this.value);
  factory _Msg.fromJson(Map<String, dynamic> j) => _Msg(j['v'] as String);
  @override
  Map<String, dynamic> toJson() => {'v': value};
  static RpcCodec<_Msg> get codec => RpcCodec(_Msg.fromJson);
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('S');
  @override
  void setup() {
    addUnaryMethod<_Msg, _Msg>(
      methodName: 'echo',
      handler: (m, {context}) async => _Msg(m.value),
      requestCodec: _Msg.codec,
      responseCodec: _Msg.codec,
    );
  }
}
