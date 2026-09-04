// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request refused with UNIMPLEMENTED for an unsupported grpc-encoding still
// ran the application handler on HTTP/1.1. The peer was told the call was never
// implemented; the server performed it anyway.
//
// Traced by wrapping the transport and recording every call the endpoint layers
// made for one such request:
//
//   sendMetadata(stream=4, endStream=true, grpc-status=12)  <- refused
//   releaseStreamId(4)                                       <- cleaned up
//   sendMetadata(stream=4, endStream=false)                  <- resurrected
//   >>> HANDLER RAN
//   sendMessage(stream=4, 16 bytes)
//   sendMetadata(stream=4, endStream=true, grpc-status=0)    <- discarded
//
// The refusal was always correct. What was wrong is in core: a frame for a
// closed stream was ignored only `if (message.methodPath == null)`, and the
// HTTP/1.1 responder tags its DATA frame with the method path too, so the
// request's own body cleared the closed-stream guard and re-opened the stream.
// Delaying the body by 300ms changed nothing, which ruled out a race.
//
// Sibling comparison, same battery, real peers on both sides -- the http2
// server tags only its HEADERS frame and was correct throughout:
//
//   http2     snappy -> grpc-status=12  handler ran=false
//   http/1.1  snappy -> grpc-status=12  handler ran=TRUE
//
// This has to be driven by a FOREIGN peer: RpcHttpCallerTransport refuses an
// unsupported encoding locally, before anything reaches the wire, so no
// rpc_dart client can reach the server's half of this negotiation.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _handlerRuns = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async {
        _handlerRuns++;
        return 'echo-ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// One foreign request over a real socket; returns the grpc-status seen.
Future<String> _ask(
  HttpClient client,
  int port, {
  String? encoding,
  Duration pauseBeforeBody = Duration.zero,
}) async {
  final body = RpcMessageFrame.encode(
    _codec.serialize('hello'.rpc),
    compressed: false,
  );
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port/Svc/Echo'),
  );
  request.headers.set('content-type', 'application/grpc');
  if (encoding != null) request.headers.set('grpc-encoding', encoding);
  request.contentLength = body.length;
  if (pauseBeforeBody > Duration.zero) {
    await Future<void>.delayed(pauseBeforeBody);
  }
  request.add(body);
  try {
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return response.headers.value('grpc-status') ?? '-';
  } on TimeoutException {
    return 'HUNG';
  }
}

void main() {
  late RpcHttpResponderTransport transport;
  late RpcResponderEndpoint responder;
  late HttpServer server;
  late HttpClient client;

  setUp(() async {
    _handlerRuns = 0;
    transport = RpcHttpResponderTransport(
      securityPolicy: const RpcSecurityPolicy(),
    );
    responder = RpcResponderEndpoint(transport: transport);
    responder.registerServiceContract(_Contract());
    responder.start();
    server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await responder.close();
    await transport.close();
    await server.close(force: true);
  });

  test('a refused encoding never reaches the handler', () async {
    final status = await _ask(client, server.port, encoding: 'snappy');

    expect(status, '12', reason: 'the refusal itself was always correct');
    expect(
      _handlerRuns,
      0,
      reason:
          'the request was answered UNIMPLEMENTED and its stream released, '
          'then its own body frame re-opened the stream and ran the handler: '
          'the caller sees a failed call while the server does the work',
    );
  });

  test('the body arriving late does not change it', () async {
    // Pinned because it is what ruled out a race: the resurrection is
    // deterministic, so no amount of delay makes the refusal stick on its own.
    await _ask(
      client,
      server.port,
      encoding: 'snappy',
      pauseBeforeBody: const Duration(milliseconds: 300),
    );
    expect(_handlerRuns, 0);
  });

  test('CONTROL: a supported encoding is served normally', () async {
    expect(await _ask(client, server.port, encoding: 'identity'), '0');
    expect(await _ask(client, server.port), '0');
    expect(_handlerRuns, 2);
  });

  test(
    'GUARD: refusals interleaved with good calls, over reused ids',
    () async {
      // RpcStreamIdManager hands ids back after release, so a long-lived server
      // reuses ids that are also in the closed-stream set. If the guard were
      // tightened wrongly, good calls would start being swallowed once ids
      // wrapped -- so drive both kinds through the same server.
      var refused = 0;
      var served = 0;
      for (var i = 0; i < 20; i++) {
        if (await _ask(client, server.port, encoding: 'snappy') == '12') {
          refused++;
        }
        if (await _ask(client, server.port) == '0') served++;
      }

      expect(refused, 20, reason: 'every bad call refused');
      expect(served, 20, reason: 'every good call served on a reused id');
      expect(
        _handlerRuns,
        20,
        reason: 'the handler ran for the good calls and only those',
      );
    },
  );
}
