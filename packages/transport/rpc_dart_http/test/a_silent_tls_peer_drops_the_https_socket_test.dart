// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An https call to a peer that accepts TCP and never answers TLS: the call is
// released while its connection is still in the handshake, and the socket it
// opened must close. Measured before the fix (P-353): the call returned at its
// deadline but the socket stayed OPEN at 16 s — dart:io's
// `SecureSocket.startConnect` cancels only the TCP connect, so nothing could
// close a socket a dead handshake owned.
//
// Two halves carry that, and they bite at different stages. Once the request
// is on the wire, `package:http` has an `HttpClientRequest` to abort and the
// abort closes the socket. While the connection is still being established
// there is no request yet — `package:http` attaches the abort trigger only
// after its `openUrl` returns — so the close comes from `HttpClient`'s
// connectTimeout firing, which cancels the connection task; the owned client's
// factory routes the task through `RpcSecureSocket`, whose cancel closes the
// socket in EITHER stage, where dart:io's own task cancels only the TCP one.
// dart:io exposes no per-request connect cancel, so this is the earliest a
// pending handshake's socket can be freed.
//
// The close is measured at the ACCEPTOR, the only side that can say a socket
// is really gone. A released call looks identical either way from the client.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

const _connectTimeout = Duration(seconds: 5);

/// A peer that accepts TCP and never writes, recording each accepted socket's
/// close.
class _Silent {
  _Silent(this._listener);

  final ServerSocket _listener;
  final List<Socket> held = [];
  final List<Completer<void>> closes = [];

  static Future<_Silent> start() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final silent = _Silent(listener);
    listener.listen((socket) {
      final closed = Completer<void>();
      silent.closes.add(closed);
      silent.held.add(socket);
      socket.listen(
        (_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
        // The peer must not answer the TLS ClientHello, but it should keep
        // reading so a client abort is not hidden behind a full send buffer.
        cancelOnError: false,
      );
    });
    return silent;
  }

  int get port => _listener.port;

  Future<void> stop() async {
    for (final socket in held) {
      socket.destroy();
    }
    await _listener.close();
  }
}

/// Fires one call at [silent] and releases it while the connection is still
/// being established. [httpClient] null means the transport builds its own —
/// the mechanism under test.
Future<_Silent> _run({
  required bool tls,
  required http.Client? httpClient,
}) async {
  final silent = await _Silent.start();
  final transport = RpcHttpCallerTransport(
    baseUrl: '${tls ? 'https' : 'http'}://127.0.0.1:${silent.port}',
    httpClient: httpClient,
    connectTimeout: _connectTimeout,
  );
  var errors = 0;
  transport.incomingMessages.listen((_) {}, onError: (Object _) => errors++);
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await silent.stop();
  });

  final id = transport.createStream();
  await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'm'));
  // Not awaited: over https the POST cannot even be sent while the handshake
  // is pending, so this completes only when the call is torn down.
  unawaited(
    transport
        .sendMessage(
          id,
          RpcMessageFrame.encode(Uint8List.fromList(<int>[1, 2, 3])),
          endStream: true,
        )
        .catchError((Object _) {}),
  );

  // Long enough for the TCP connect and the TLS handshake to be in flight,
  // short of the connect timeout.
  await Future<void>.delayed(const Duration(seconds: 1));
  transport.releaseStreamId(id);
  expect(errors, 0, reason: 'ordinary teardown looks like a failure');
  return silent;
}

void main() {
  test(
    'WITNESS: releasing an https call stuck in the TLS handshake closes its socket',
    () async {
      final silent = await _run(tls: true, httpClient: null);
      await silent.closes.single.future.timeout(
        _connectTimeout + const Duration(seconds: 4),
        onTimeout: () => fail(
          'the released https call kept its socket past the connect timeout: '
          'the handshake-cancel fix is not in place',
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CONTROL: over plain http the same release already closed the socket
  // before the fix — the abort reaches a request `openUrl` has returned. If
  // this arm fails, the bench cannot see a close and the witness proves
  // nothing.
  test(
    'CONTROL: releasing an http call closes its socket',
    () async {
      final silent = await _run(tls: false, httpClient: null);
      await silent.closes.single.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => fail('the released http call kept its socket'),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CANARY: the connect timeout alone is not the fix. A caller-supplied client
  // WITH the same connectTimeout but WITHOUT the connection factory — dart:io's
  // own secure connect — cancels only the TCP stage when the timeout fires,
  // and the socket the dead handshake owns stays open.
  test(
    'CANARY: a timeout without the factory keeps the socket',
    () async {
      final own = HttpClient()..connectionTimeout = _connectTimeout;
      final silent = await _run(tls: true, httpClient: IOClient(own));
      await expectLater(
        silent.closes.single.future.timeout(
          _connectTimeout + const Duration(seconds: 4),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
