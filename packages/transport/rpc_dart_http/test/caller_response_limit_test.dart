// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttpCallerTransport read the response with http.Response.fromStream, which
// buffers the whole body before anything inspects it -- and the transport took
// no RpcSecurityPolicy at all. The responder bounds the REQUEST body against
// maxMessageLengthBytes; the caller had no bound in the other direction, so
// whatever a server, a proxy or a captive portal sent was allocated in full.
//
// Measured with a server answering 192 MiB, default policy, resident memory
// across one call:
//
//   before: grew by 756 MiB, then failed with
//           "gRPC frame buffer overflow: 201326592 bytes (max: 16777221)"
//   after : grew by 19 MiB, and failed with the limit named
//
// The ceiling existed. It just fired after the damage, inside the frame parser,
// once the bytes were already resident three times over.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A server that answers every POST with [bodyBytes] of payload.
///
/// [framed] wraps the payload as a real gRPC message so a response within the
/// limit is something the client can actually decode.
Future<HttpServer> _serverSending({
  required int bodyBytes,
  bool framed = false,
  int status = 200,
}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  unawaited(() async {
    await for (final request in server) {
      await request.drain<void>();
      request.response.statusCode = status;
      request.response.headers.set('content-type', 'application/grpc+proto');
      request.response.headers.set('grpc-status', '0');
      if (framed) {
        request.response.add(
          RpcMessageFrame.encode(
            _codec.serialize(('p' * bodyBytes).rpc),
            compressed: false,
          ),
        );
      } else {
        const chunk = 1 << 16;
        final filler = List<int>.filled(chunk, 0x41);
        var written = 0;
        while (written < bodyBytes) {
          final take = (bodyBytes - written).clamp(0, chunk);
          request.response.add(
            take == chunk ? filler : filler.sublist(0, take),
          );
          written += take;
        }
      }
      await request.response.close();
    }
  }());
  return server;
}

Future<Object?> _call(HttpServer server, {RpcSecurityPolicy? policy}) async {
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
    policy: policy ?? const RpcSecurityPolicy(),
  );
  final caller = RpcCallerEndpoint(transport: transport);
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 30));
    return r.value;
  } catch (e) {
    return e;
  } finally {
    await caller.close();
    await transport.close();
  }
}

void main() {
  test(
    'a response past the policy limit is refused, naming the limit',
    () async {
      const limit = 64 * 1024;
      final server = await _serverSending(bodyBytes: 8 * 1024 * 1024);
      addTearDown(() => server.close(force: true));

      final result = await _call(
        server,
        policy: const RpcSecurityPolicy(maxMessageLengthBytes: limit),
      );

      expect(result, isA<Object>());
      expect(
        result.toString(),
        contains('exceeds the configured limit of $limit bytes'),
        reason:
            'the body used to be buffered whole and only then rejected by the '
            'frame parser, against ITS ceiling rather than the configured one',
      );
    },
  );

  test('the transport reports the policy it was given', () {
    // The endpoint layers read maxMessageLengthBytes through this interface;
    // without it the parser falls back to its own defaults.
    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:1',
      policy: const RpcSecurityPolicy(maxMessageLengthBytes: 4321),
    );
    addTearDown(transport.close);

    expect(transport, isA<IRpcSecurityPolicyAware>());
    expect(
      (transport as IRpcSecurityPolicyAware)
          .securityPolicy
          .maxMessageLengthBytes,
      4321,
    );
  });

  test('CONTROL: an ordinary response still round-trips', () async {
    // GUARD: the read was rewritten from Response.fromStream to a streamed
    // one, so the ordinary path has to be pinned.
    final server = await _serverSending(bodyBytes: 16, framed: true);
    addTearDown(() => server.close(force: true));

    expect(await _call(server), isA<String>());
  });

  test('a non-200 still maps to its gRPC status', () async {
    // GUARD: the status branch now drains the body before reporting, so it
    // must still report the same thing.
    final server = await _serverSending(bodyBytes: 32, status: 503);
    addTearDown(() => server.close(force: true));

    expect(
      await _call(server),
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.unavailable,
      ),
    );
  });
}
