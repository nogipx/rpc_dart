// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The http2 caller parses DATA into whole gRPC frames itself and hands only
// those up, so a response cut inside a frame and followed by an OK trailer
// ended OK, with the partial frame left in the stream's parser.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A raw h2 peer answering every stream with two whole frames, [tail] and an
/// OK trailer.
Future<int> _peer(List<int> tail) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  addTearDown(socket.close);
  final frame = RpcMessageFrame.encode(_codec.serialize('item'.rpc));
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc'),
      ]);
      stream.sendData([...frame, ...frame, ...tail]);
      stream.sendHeaders([
        http2.Header.ascii('grpc-status', '0'),
      ], endStream: true);
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket.port;
}

Future<(List<String>, Object?)> _call(int port) async {
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: port,
  );
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await client.close();
  });
  final items = <String>[];
  Object? error;
  try {
    await caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'items',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .forEach((m) => items.add(m.value))
        .timeout(const Duration(seconds: 10));
  } catch (e) {
    error = e;
  }
  return (items, error);
}

void main() {
  test('WITNESS a response cut inside a frame ends with INTERNAL', () async {
    final frame = RpcMessageFrame.encode(_codec.serialize('item'.rpc));
    final (items, error) = await _call(await _peer(frame.sublist(0, 7)));
    expect(items, ['item', 'item']);
    expect(
      error,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.internal,
      ),
    );
  });

  test('GUARD a response that ends between frames ends OK', () async {
    final frame = RpcMessageFrame.encode(_codec.serialize('item'.rpc));
    final (items, error) = await _call(await _peer(frame));
    expect(items, ['item', 'item', 'item']);
    expect(error, isNull);
  });
}
