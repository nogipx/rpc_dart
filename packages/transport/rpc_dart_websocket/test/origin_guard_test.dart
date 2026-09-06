// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// WebSocket is NOT subject to the same-origin policy: a browser opens a socket
// from any page to any server and attaches the user's ambient credentials.
// Checking the `Origin` header at the handshake is the only protocol-level
// defence, and the server entry point could not do it -- `server.transform(...)`
// consumes the HttpServer stream whole, so the application never saw a request
// and had nowhere to refuse one. Measured against this server:
//
//   Origin: https://evil.example  ->  SERVED "the users private data"
//
// The HTTP/1.1 transport has shipped a CORS policy since round 44, so an
// operator who had locked down one transport was wide open on the other.
//
// A request with NO Origin is allowed on purpose: Origin is attached by
// browsers, every non-browser client sends none, and the attack being stopped
// is a page riding credentials it cannot read.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'secret',
      handler: (request, {RpcContext? context}) async => 'private'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({HttpServer http, RpcWebSocketServer server, List<int> opened});

Future<_Rig> _serve({
  Set<String>? allowedOrigins,
  bool Function(HttpRequest request)? allowUpgrade,
}) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final opened = <int>[];
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(
      http,
      allowedOrigins: allowedOrigins,
      allowUpgrade: allowUpgrade,
    ),
    onEndpointCreated: (e) {
      opened.add(1);
      e.registerServiceContract(_Svc());
    },
  );
  await server.start();
  return (http: http, server: server, opened: opened);
}

/// Connects with [origin] and returns the answer, or the failure's type name.
Future<String> _call(_Rig rig, {String? origin}) async {
  WebSocket socket;
  try {
    socket = await WebSocket.connect(
      'ws://127.0.0.1:${rig.http.port}',
      headers: origin == null ? null : {'origin': origin},
    );
  } on WebSocketException {
    return 'REFUSED';
  }
  final client = RpcWebSocketCallerTransport(IOWebSocketChannel(socket));
  final caller = RpcCallerEndpoint(transport: client);
  try {
    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'secret',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withTimeout(const Duration(seconds: 5)),
    );
    return answer.value;
  } finally {
    await caller.close();
    await client.close();
  }
}

/// Sends a raw upgrade request carrying [origins] as separate header lines and
/// returns the status line, or 'NO ANSWER'.
///
/// Raw because no HTTP client will send a header twice on request.
Future<String> _rawHandshake(_Rig rig, List<String> origins) async {
  final socket = await Socket.connect('127.0.0.1', rig.http.port);
  final buffer = StringBuffer()
    ..write('GET / HTTP/1.1\r\n')
    ..write('Host: 127.0.0.1:${rig.http.port}\r\n')
    ..write('Upgrade: websocket\r\n')
    ..write('Connection: Upgrade\r\n')
    ..write('Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n')
    ..write('Sec-WebSocket-Version: 13\r\n');
  for (final origin in origins) {
    buffer.write('Origin: $origin\r\n');
  }
  buffer.write('\r\n');
  socket.write(buffer.toString());
  await socket.flush();

  final chunks = <int>[];
  try {
    await socket
        .listen(chunks.addAll)
        .asFuture<void>()
        .timeout(const Duration(seconds: 3));
  } on TimeoutException {
    // The peer kept the connection open; what arrived is enough.
  }
  await socket.close();
  if (chunks.isEmpty) return 'NO ANSWER';
  return String.fromCharCodes(chunks).split('\r\n').first;
}

void _teardown(_Rig rig) {
  addTearDown(() async {
    await rig.server.stop();
    await rig.http.close(force: true);
  });
}

void main() {
  test('a cross-origin handshake is refused', () async {
    final rig = await _serve(allowedOrigins: {'https://app.example.com'});
    _teardown(rig);

    expect(await _call(rig, origin: 'https://evil.example'), 'REFUSED');
    expect(
      rig.opened,
      isEmpty,
      reason: 'a refused handshake must not reach the endpoint layer at all',
    );
  });

  test('a refusal is answered 403, not a dropped connection', () async {
    // The peer must be told why. Answering after the upgrade would be too late
    // -- the response is committed by then -- so this also pins that the check
    // runs BEFORE WebSocketTransformer.
    final rig = await _serve(allowedOrigins: {'https://app.example.com'});
    _teardown(rig);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${rig.http.port}/'),
    );
    request.headers.set('origin', 'https://evil.example');
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.forbidden);
  });

  test('an allowed origin still connects', () async {
    final rig = await _serve(allowedOrigins: {'https://app.example.com'});
    _teardown(rig);

    expect(await _call(rig, origin: 'https://app.example.com'), 'private');
  });

  test('the match is case-insensitive', () async {
    final rig = await _serve(allowedOrigins: {'https://App.Example.com'});
    _teardown(rig);

    expect(await _call(rig, origin: 'https://app.example.COM'), 'private');
  });

  test('a client sending no Origin still connects', () async {
    // Load-bearing: Origin is attached by browsers, so refusing its absence
    // would break every Dart, Go and CLI client while stopping nobody.
    final rig = await _serve(allowedOrigins: {'https://app.example.com'});
    _teardown(rig);

    expect(await _call(rig), 'private');
  });

  test('GUARD: unset allows any origin, as before', () async {
    final rig = await _serve();
    _teardown(rig);

    expect(await _call(rig, origin: 'https://evil.example'), 'private');
  });

  group('the guard cannot take the process down', () {
    // It runs inside the accept loop's event handler, which is the ROOT ZONE:
    // anything it throws is an unhandled async error and kills the isolate.
    // Reading the origin with `headers.value()` did exactly that on a request
    // carrying two Origin headers -- six lines of raw HTTP, unauthenticated,
    // one request, whole server process gone. Without the fix these tests do
    // not fail, they CRASH the suite.

    test('two Origin headers are refused, not fatal', () async {
      final rig = await _serve(allowedOrigins: {'https://app.example.com'});
      _teardown(rig);

      expect(
        await _rawHandshake(rig, [
          'https://app.example.com',
          'https://evil.example',
        ]),
        contains('403'),
      );
      expect(
        await _call(rig, origin: 'https://app.example.com'),
        'private',
        reason: 'the accept loop must still be alive',
      );
    });

    test('two copies of an ALLOWED origin are refused too', () async {
      // Not "any of them matches": that would let an attacker append a
      // permitted origin to their own and walk through. One Origin header is
      // what the Fetch standard sends; more than one is malformed.
      final rig = await _serve(allowedOrigins: {'https://app.example.com'});
      _teardown(rig);

      expect(
        await _rawHandshake(rig, [
          'https://app.example.com',
          'https://app.example.com',
        ]),
        contains('403'),
      );
    });

    test(
      'a throwing allowUpgrade refuses instead of killing the loop',
      () async {
        // The predicate is user code, so it can always throw -- a DI lookup, a
        // bad cast, a null. It must cost one connection, not the server.
        final rig = await _serve(
          allowUpgrade: (request) => throw StateError('boom'),
        );
        _teardown(rig);

        expect(await _call(rig), 'REFUSED');
        expect(await _rawHandshake(rig, const []), contains('403'));
      },
    );
  });

  group('allowUpgrade', () {
    test('refuses on its own', () async {
      final rig = await _serve(
        allowUpgrade: (request) =>
            request.uri.queryParameters['token'] == 'good',
      );
      _teardown(rig);

      expect(await _call(rig), 'REFUSED');
    });

    test('admits when it accepts', () async {
      final rig = await _serve(allowUpgrade: (request) => true);
      _teardown(rig);

      expect(await _call(rig, origin: 'https://anywhere.example'), 'private');
    });

    test('both checks must accept', () async {
      // An allowed origin must not buy a pass on the predicate.
      final rig = await _serve(
        allowedOrigins: {'https://app.example.com'},
        allowUpgrade: (request) => false,
      );
      _teardown(rig);

      expect(await _call(rig, origin: 'https://app.example.com'), 'REFUSED');
    });
  });
}
