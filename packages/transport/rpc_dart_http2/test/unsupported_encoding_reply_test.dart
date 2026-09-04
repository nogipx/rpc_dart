// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer that asks for a compression algorithm this build does not have is
// refused with UNIMPLEMENTED -- correctly. The gRPC spec (PROTOCOL-HTTP2) also
// requires that refusal to carry `grpc-accept-encoding` listing what the server
// DOES support, so the client can retry with something usable. Without it,
// UNIMPLEMENTED is a dead end.
//
// Measured on the wire against RpcHttp2Server:
//
//   grpc-encoding: <none>   -> grpc-status=0   (control)
//   grpc-encoding: identity -> grpc-status=0   (control)
//   grpc-encoding: br       -> grpc-status=12  accept-encoding ABSENT
//   grpc-encoding: snappy   -> grpc-status=12  accept-encoding ABSENT
//
// after: both rejections carry `accept-encoding=identity,gzip`.
//
// The test speaks raw package:http2 ON PURPOSE. rpc_dart's own caller rejects
// an unsupported encoding locally, before anything reaches the wire, so a
// normal client can never exercise the server's side of this negotiation --
// which is exactly why it went unnoticed. Only a foreign peer gets here, and a
// foreign peer is the whole point of the header.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends one request with [encoding] and returns every response header seen.
Future<Map<String, String>> _ask(int port, String? encoding) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final conn = http2.ClientTransportConnection.viaSocket(socket);
  final stream = conn.makeRequest([
    http2.Header.ascii(':method', 'POST'),
    http2.Header.ascii(':path', '/Svc/Echo'),
    http2.Header.ascii(':scheme', 'http'),
    http2.Header.ascii(':authority', '127.0.0.1:$port'),
    http2.Header.ascii('content-type', 'application/grpc+proto'),
    http2.Header.ascii('te', 'trailers'),
    if (encoding != null) http2.Header.ascii('grpc-encoding', encoding),
  ]);
  stream.sendData(
    RpcMessageFrame.encode(_codec.serialize('x'.rpc), compressed: false),
    endStream: true,
  );

  final headers = <String, String>{};
  await for (final message in stream.incomingMessages) {
    if (message is http2.HeadersStreamMessage) {
      for (final header in message.headers) {
        headers[String.fromCharCodes(header.name)] = String.fromCharCodes(
          header.value,
        );
      }
    }
  }
  await conn.terminate();
  return headers;
}

void main() {
  late RpcHttp2Server server;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );
    await server.start();
  });

  tearDown(() => server.stop());

  test('an unsupported encoding is refused WITH grpc-accept-encoding', () async {
    final headers = await _ask(server.port, 'br');

    expect(headers['grpc-status'], RpcStatus.unimplemented.toString());
    expect(
      headers['grpc-accept-encoding'],
      isNotNull,
      reason:
          'UNIMPLEMENTED without grpc-accept-encoding is a dead end: the peer '
          'is refused for its choice of algorithm and told nothing about which '
          'ones would work',
    );
    expect(
      headers['grpc-accept-encoding'],
      contains('identity'),
      reason: 'identity is always supported and must be offered',
    );
  });

  test('GUARD: a request with no encoding still succeeds', () async {
    // The check fires only for a PRESENT, unsupported value. Rejecting here
    // would break every peer that never mentions compression at all.
    final headers = await _ask(server.port, null);
    expect(headers['grpc-status'], '0');
    expect(headers['grpc-accept-encoding'], isNull);
  });

  test('GUARD: identity still succeeds', () async {
    final headers = await _ask(server.port, 'identity');
    expect(headers['grpc-status'], '0');
  });

  test('GUARD: an unrelated failure carries no accept-encoding', () async {
    // The header belongs to this one rejection, not to every trailer -- adding
    // it everywhere would be noise on the wire for unrelated failures.
    final socket = await Socket.connect('127.0.0.1', server.port);
    final conn = http2.ClientTransportConnection.viaSocket(socket);
    final stream = conn.makeRequest([
      http2.Header.ascii(':method', 'POST'),
      http2.Header.ascii(':path', '/Svc/NoSuchMethod'),
      http2.Header.ascii(':scheme', 'http'),
      http2.Header.ascii(':authority', '127.0.0.1:${server.port}'),
      http2.Header.ascii('content-type', 'application/grpc+proto'),
      http2.Header.ascii('te', 'trailers'),
    ]);
    stream.sendData(
      RpcMessageFrame.encode(_codec.serialize('x'.rpc), compressed: false),
      endStream: true,
    );

    final headers = <String, String>{};
    await for (final message in stream.incomingMessages) {
      if (message is http2.HeadersStreamMessage) {
        for (final header in message.headers) {
          headers[String.fromCharCodes(header.name)] = String.fromCharCodes(
            header.value,
          );
        }
      }
    }
    await conn.terminate();

    expect(headers['grpc-status'], isNot('0'));
    expect(
      headers['grpc-accept-encoding'],
      isNull,
      reason: 'only the encoding rejection needs to advertise alternatives',
    );
  });
}
