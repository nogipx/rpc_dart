// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A header frame that fails RpcSecurityPolicy.validateMetadata throws out of
// _handleIncomingHeaders BEFORE _emit, so the responder pipeline never gets
// state for the stream and never replies. _emitStreamError reports INWARD, to a
// pipeline with nothing to attach the error to -- so the peer was simply left
// waiting, and the HTTP/2 stream stayed in _incomingStreams forever.
//
// Measured with a `:path` carrying no leading slash, which the policy rejects
// and which only a FOREIGN peer can send (rpc_dart's own caller always builds
// the path itself -- the same blind spot that hid the missing
// grpc-accept-encoding one round earlier):
//
//   before: 20 requests sent, 0 answered
//           server transport incomingStreams: 20, responder openStreams: 20
//   after : 20 sent, 20 answered, both counters back to 0
//
// The peer chooses the path, so this was an unauthenticated way to pin
// maxActiveStreams worth of slots with requests that can never complete.

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

Uint8List get _body =>
    RpcMessageFrame.encode(_codec.serialize('x'.rpc), compressed: false);

/// Opens [count] streams with [path] on ONE connection and reports how many
/// were answered.
Future<({int answered, Map<String, String> lastHeaders})> _ask(
  int port,
  String path, {
  int count = 1,
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final conn = http2.ClientTransportConnection.viaSocket(socket);
  var answered = 0;
  var lastHeaders = <String, String>{};

  final waits = <Future<void>>[];
  for (var i = 0; i < count; i++) {
    final stream = conn.makeRequest([
      http2.Header.ascii(':method', 'POST'),
      http2.Header.ascii(':path', path),
      http2.Header.ascii(':scheme', 'http'),
      http2.Header.ascii(':authority', '127.0.0.1:$port'),
      http2.Header.ascii('content-type', 'application/grpc+proto'),
      http2.Header.ascii('te', 'trailers'),
    ]);
    stream.sendData(_body, endStream: true);
    waits.add(
      stream.incomingMessages
          .forEach((message) {
            if (message is http2.HeadersStreamMessage) {
              final headers = <String, String>{};
              for (final h in message.headers) {
                headers[String.fromCharCodes(h.name)] = String.fromCharCodes(
                  h.value,
                );
              }
              lastHeaders = headers;
            }
          })
          .timeout(const Duration(seconds: 6))
          .then((_) => answered++)
          // A stream nobody answers never completes; that is the defect, so
          // count it as unanswered rather than failing the whole run.
          .catchError((Object _) => answered),
    );
  }

  await Future.wait(waits);
  await conn.terminate();
  return (answered: answered, lastHeaders: lastHeaders);
}

void main() {
  late RpcHttp2Server server;
  RpcResponderEndpoint? endpoint;

  setUp(() async {
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

  test('a request rejected by the policy is answered, not dropped', () async {
    // ':path' with no leading slash: refused by isValidMethodPath.
    final result = await _ask(server.port, 'SvcEcho');

    expect(
      result.answered,
      1,
      reason: 'the peer was left waiting forever on a stream nobody answered',
    );
    expect(
      result.lastHeaders['grpc-status'],
      RpcStatus.invalidArgument.toString(),
    );
  });

  test('rejected streams do not accumulate on the server', () async {
    final result = await _ask(server.port, 'SvcEcho', count: 20);
    expect(result.answered, 20);

    await Future<void>.delayed(const Duration(milliseconds: 300));

    final details = (await endpoint!.transport.health()).details;
    expect(
      details['incomingStreams'],
      0,
      reason:
          'the peer chooses the path, so streams it can strand are slots it '
          'controls -- 20 of these used to sit open forever',
    );
    expect(endpoint!.collectEndpointMetrics()['openStreams'], 0);
  });

  test('GUARD: a well-formed request still succeeds', () async {
    final result = await _ask(server.port, '/Svc/Echo');
    expect(result.answered, 1);
    expect(result.lastHeaders['grpc-status'], '0');
  });

  test('GUARD: other rejections keep their own status', () async {
    // These already answered correctly and must not be flattened into one
    // generic error by the new path.
    final unknown = await _ask(server.port, '/Nope/Echo');
    expect(unknown.answered, 1);
    expect(
      unknown.lastHeaders['grpc-status'],
      RpcStatus.unimplemented.toString(),
      reason: 'an unknown service is UNIMPLEMENTED, not INVALID_ARGUMENT',
    );

    final oneSegment = await _ask(server.port, '/Echo');
    expect(oneSegment.answered, 1);
    expect(
      oneSegment.lastHeaders['grpc-status'],
      RpcStatus.invalidArgument.toString(),
    );
  });

  test('GUARD: the connection still serves after a rejection', () async {
    await _ask(server.port, 'SvcEcho');
    final ok = await _ask(server.port, '/Svc/Echo');
    expect(ok.lastHeaders['grpc-status'], '0');
  });
}
