// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// gRPC is POST-only, and nothing checked. EVERY method executed the handler:
//
//   POST GET HEAD PUT DELETE OPTIONS BREW  ->  7 of 7 ran, all grpc-status=0
//
// GET is the one that matters. A browser can be made to issue a cross-origin
// GET without a preflight, while a POST carrying `content-type:
// application/grpc` cannot leave the origin unprompted -- so accepting GET
// turned every unary method into something an attacker's page could trigger.
// HEAD and the rest are the same hole, less reachable.
//
// rpc_dart's own caller hard-codes POST in rpcMetadataToHttp2RequestHeaders,
// which is why no existing test could reach this: only a foreign peer chooses
// the method. Same blind spot as the missing grpc-accept-encoding and the
// unanswered policy rejection -- see the raw-peer rule those rounds recorded.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _handlerRuns = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Mutate',
      handler: (request, {RpcContext? context}) async {
        _handlerRuns++;
        return 'mutated'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends one request with [method] and returns the response headers.
Future<Map<String, String>> _ask(int port, String method) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final conn = http2.ClientTransportConnection.viaSocket(socket);
  final stream = conn.makeRequest([
    http2.Header.ascii(':method', method),
    http2.Header.ascii(':path', '/Svc/Mutate'),
    http2.Header.ascii(':scheme', 'http'),
    http2.Header.ascii(':authority', '127.0.0.1:$port'),
    http2.Header.ascii('content-type', 'application/grpc+proto'),
    http2.Header.ascii('te', 'trailers'),
  ]);
  stream.sendData(
    RpcMessageFrame.encode(_codec.serialize('x'.rpc), compressed: false),
    endStream: true,
  );

  final headers = <String, String>{};
  await stream.incomingMessages
      .forEach((message) {
        if (message is http2.HeadersStreamMessage) {
          for (final h in message.headers) {
            headers[String.fromCharCodes(h.name)] = String.fromCharCodes(
              h.value,
            );
          }
        }
      })
      .timeout(const Duration(seconds: 6));
  await conn.terminate();
  return headers;
}

void main() {
  late RpcHttp2Server server;
  RpcResponderEndpoint? endpoint;

  setUp(() async {
    _handlerRuns = 0;
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) {
        endpoint = e;
        e.registerServiceContract(_Contract());
      },
    );
    await server.start();
  });

  tearDown(() => server.stop());

  test('a GET never reaches the handler', () async {
    final headers = await _ask(server.port, 'GET');

    expect(
      _handlerRuns,
      0,
      reason:
          'a cross-origin GET needs no preflight, so executing one turns every '
          'unary method into something an attacker page can trigger',
    );
    expect(headers['grpc-status'], RpcStatus.invalidArgument.toString());
    expect(
      Uri.decodeComponent(headers['grpc-message'] ?? ''),
      contains('POST'),
      reason: 'the refusal should name what the peer got wrong',
    );
  });

  test('no method other than POST reaches the handler', () async {
    for (final method in const [
      'GET',
      'HEAD',
      'PUT',
      'DELETE',
      'OPTIONS',
      'BREW',
    ]) {
      final headers = await _ask(server.port, method);
      expect(
        headers['grpc-status'],
        RpcStatus.invalidArgument.toString(),
        reason: '$method must be refused',
      );
    }
    expect(_handlerRuns, 0);
  });

  test('GUARD: POST still works', () async {
    final headers = await _ask(server.port, 'POST');
    expect(headers['grpc-status'], '0');
    expect(_handlerRuns, 1);
  });

  test('GUARD: a refused method is answered and released', () async {
    // The refusal rides the same path as the policy rejection fixed in
    // a70c4799, so it must not strand the stream either -- an unanswered
    // rejection is a slot the peer keeps.
    for (var i = 0; i < 10; i++) {
      await _ask(server.port, 'GET');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final details = (await endpoint!.transport.health()).details;
    expect(details['incomingStreams'], 0);
    expect(endpoint!.collectEndpointMetrics()['openStreams'], 0);
  });

  test('GUARD: the connection still serves POST after a refusal', () async {
    await _ask(server.port, 'GET');
    final headers = await _ask(server.port, 'POST');
    expect(headers['grpc-status'], '0');
    expect(_handlerRuns, 1);
  });
}
