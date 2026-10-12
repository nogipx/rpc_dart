// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary response body of one whole gRPC frame and the start of a second,
// under grpc-status 0: the call returned the first message OK, where every
// streaming shape ends a response cut mid-frame with INTERNAL.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A raw HTTP/1.1 peer answering one whole frame, [extra] and grpc-status 0.
Future<int> _peer(List<int> extra) async {
  final server = await ServerSocket.bind('127.0.0.1', 0);
  addTearDown(server.close);
  final body = [
    ...RpcMessageFrame.encode(_codec.serialize('item'.rpc)),
    ...extra,
  ];
  server.listen((s) {
    final seen = BytesBuilder();
    var answered = false;
    s.listen((b) async {
      seen.add(b);
      if (answered) return;
      if (!latin1.decode(seen.toBytes()).contains('\r\n\r\n')) return;
      answered = true;
      s.add([
        ...ascii.encode(
          'HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\n'
          'grpc-status: 0\r\nconnection: close\r\n'
          'content-length: ${body.length}\r\n\r\n',
        ),
        ...body,
      ]);
      await s.flush();
      await s.close();
    }, onError: (Object _) {});
  });
  return server.port;
}

Future<Object?> _unary(int port) async {
  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:$port'),
  );
  addTearDown(caller.close);
  return caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .then<Object?>((r) => r.value, onError: (Object e) => e)
      .timeout(const Duration(seconds: 5));
}

void main() {
  test(
    'WITNESS a unary response with a cut second frame ends with INTERNAL',
    () async {
      expect(
        await _unary(await _peer(const [0, 0, 0])),
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.internal,
        ),
      );
    },
  );

  test('GUARD a unary response of one whole frame ends OK', () async {
    expect(await _unary(await _peer(const [])), 'item');
  });
}
