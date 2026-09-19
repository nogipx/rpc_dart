// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CONTINUATION-flood guard lived only in `RpcHttp2Server`. But
// `RpcHttp2ResponderTransport` is exported and takes an already-built
// `ServerTransportConnection`, so anyone running their own accept loop — for
// TLS, ALPN, or to share a port — wired package:http2 straight to the socket
// and the guard never ran, while their `policy.maxMetadataBytes` read as if it
// were enforced.
//
// Same policy, same 64 MiB flood, frames the server took before it stopped
// reading:
//
//   RpcHttp2Server                 65 of 4096
//   own accept loop, raw         4096 of 4096     <- unbounded
//   own accept loop, overStreams   65 of 4096
//
// `overStreams` also applies the advertised MAX_CONCURRENT_STREAMS, the other
// part of the policy that cannot be attached to a connection after it exists.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _policy = RpcSecurityPolicy(maxMetadataBytes: 64 * 1024);
const _preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';
const _frames = 512;
const _payloadBytes = 16384;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Uint8List _frameHeader({
  required int length,
  required int type,
  required int flags,
  required int streamId,
}) {
  final h = Uint8List(9);
  h[0] = (length >> 16) & 0xFF;
  h[1] = (length >> 8) & 0xFF;
  h[2] = length & 0xFF;
  h[3] = type;
  h[4] = flags;
  h[5] = (streamId >> 24) & 0x7F;
  h[6] = (streamId >> 16) & 0xFF;
  h[7] = (streamId >> 8) & 0xFF;
  h[8] = streamId & 0xFF;
  return h;
}

/// Opens a header block and never ends it. Returns how many CONTINUATION frames
/// the server took before it stopped reading.
Future<int> _flood(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
  unawaited(socket.done.catchError((Object _) => socket));

  socket.add(_preface.codeUnits);
  socket.add(_frameHeader(length: 0, type: 0x4, flags: 0, streamId: 0));
  socket.add(_frameHeader(length: 0, type: 0x1, flags: 0, streamId: 1));

  final payload = Uint8List(_payloadBytes);
  final cont = _frameHeader(
    length: _payloadBytes,
    type: 0x9,
    flags: 0,
    streamId: 1,
  );

  var sent = 0;
  try {
    for (var i = 0; i < _frames; i++) {
      socket.add(cont);
      socket.add(payload);
      sent = i + 1;
      // A server that stopped reading either throws here or BLOCKS, and which
      // one is the OS's choice; the timeout turns a block into a number rather
      // than a hang. The same lesson the sibling flood test records.
      if (i % 32 == 0) {
        await socket.flush().timeout(const Duration(seconds: 3));
      }
    }
    await socket.flush().timeout(const Duration(seconds: 3));
  } catch (_) {
    // reset or wedged — either way it stopped taking it
  }
  socket.destroy();
  return sent;
}

/// An own accept loop, the shape a user writes for TLS or a shared port.
Future<ServerSocket> _ownAcceptLoop(List<RpcResponderEndpoint> keep) async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  listener.listen((socket) {
    final transport = RpcHttp2ResponderTransport.overStreams(
      incoming: socket,
      outgoing: socket,
      destroy: socket.destroy,
      policy: _policy,
    );
    final endpoint = RpcResponderEndpoint(transport: transport);
    endpoint.registerServiceContract(_Contract());
    endpoint.start();
    keep.add(endpoint);
  });
  return listener;
}

void main() {
  final endpoints = <RpcResponderEndpoint>[];
  ServerSocket? listener;

  tearDown(() async {
    for (final e in endpoints) {
      await e.close().catchError((_) {});
    }
    endpoints.clear();
    await listener?.close();
    listener = null;
  });

  test('WITNESS: overStreams bounds a CONTINUATION flood', () async {
    listener = await _ownAcceptLoop(endpoints);

    final accepted = await _flood(listener!.port);

    expect(
      accepted,
      lessThan(_frames),
      reason:
          'the peer opened a header block and never ended it, and all '
          '$accepted of $_frames frames were buffered below every rpc_dart '
          'limit — the guard did not run on this construction path',
    );
  });

  test('GUARD: an ordinary call still works through overStreams', () async {
    // The guard forwards every byte untouched; a real request must be unaffected.
    listener = await _ownAcceptLoop(endpoints);

    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: listener!.port,
    ).timeout(const Duration(seconds: 6));
    final caller = RpcCallerEndpoint(transport: transport);

    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 6));

    expect(r.value, 'echo-ok');

    await caller.close().catchError((_) {});
    await transport.close().catchError((_) {});
  });
}
