// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The http2 responder parses DATA into whole gRPC frames itself and hands only
// those up, so a request that ended inside a frame reached the handler with
// its last message gone: a client stream answered OK on an empty request
// stream. The request can end on a DATA frame, on an empty DATA frame of its
// own, or on trailers; each is a separate path here.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'items',
      handler: (r, {RpcContext? context}) async* {
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      handler: (reqs, {RpcContext? context}) async =>
          (await reqs.map((r) => r.value).toList()).join(',').rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chat',
      handler: (reqs, {RpcContext? context}) async* {
        yield (await reqs.map((r) => r.value).toList()).join(',').rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends [body] to /Svc/[method], ending the request as [end] says, and
/// returns the grpc-status the server answers.
Future<String?> _status(
  int port,
  String method,
  List<int> body,
  String end,
) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final conn = http2.ClientTransportConnection.viaSocket(socket);
  addTearDown(conn.terminate);
  final stream = conn.makeRequest([
    http2.Header.ascii(':method', 'POST'),
    http2.Header.ascii(':path', '/Svc/$method'),
    http2.Header.ascii(':scheme', 'http'),
    http2.Header.ascii(':authority', '127.0.0.1:$port'),
    http2.Header.ascii('content-type', 'application/grpc'),
    http2.Header.ascii('te', 'trailers'),
  ]);
  switch (end) {
    case 'data':
      stream.sendData(body, endStream: true);
    case 'empty data':
      stream.sendData(body);
      stream.sendData(const [], endStream: true);
    default:
      stream.sendData(body);
      stream.sendHeaders([http2.Header.ascii('x-end', '1')], endStream: true);
  }
  String? status;
  await for (final m in stream.incomingMessages.timeout(
    const Duration(seconds: 5),
  )) {
    if (m is http2.HeadersStreamMessage) {
      for (final h in m.headers) {
        if (String.fromCharCodes(h.name) == 'grpc-status') {
          status = String.fromCharCodes(h.value);
        }
      }
    }
  }
  return status;
}

void main() {
  late RpcHttp2Server server;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
  });

  tearDown(() => server.stop());

  final frame = RpcMessageFrame.encode(_codec.serialize('x'.rpc));

  for (final method in ['echo', 'items', 'collect', 'chat']) {
    for (final end in ['data', 'empty data', 'trailers']) {
      test('WITNESS $method, a request cut inside its frame and ended on '
          '$end, is refused INTERNAL', () async {
        expect(
          await _status(server.port, method, frame.sublist(0, 7), end),
          '${RpcStatus.internal}',
        );
      });

      test(
        'GUARD $method, a whole request ended on $end, is answered OK',
        () async {
          expect(await _status(server.port, method, frame, end), '0');
        },
      );
    }
  }

  for (final method in ['collect', 'chat']) {
    test('WITNESS $method, a whole message and the start of a second, is '
        'refused INTERNAL', () async {
      expect(
        await _status(server.port, method, [...frame, 0, 0, 0], 'empty data'),
        '${RpcStatus.internal}',
      );
    });
  }
}
