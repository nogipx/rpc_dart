// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller ran OUR metadata policy over the PEER's trailers and read
// `grpc-status` out of them only afterwards, so a limit tripped by one detail
// header destroyed the status the call was about.
//
// The shape is grpc-go's rich error model: `grpc-status-details-bin` carrying a
// base64 Status proto, against a `maxHeaderValueBytes` of 8 KiB. Measured against
// a raw package:http2 server answering `grpc-status: 9`:
//
//     details-bin 16 B      status 9  -- the precondition failed
//     details-bin 10 KiB    status 3  -- Invalid metadata header value
//     200 trailer headers   status 3  -- Too many metadata headers
//
// A trailer frame is fully decoded and resident by the time the policy runs, so
// refusing it buys no memory -- it only decided whose answer ended the call.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// What the server attaches beside a real `grpc-status: 9`.
late List<http2.Header> _extra;

/// A server that always answers FAILED_PRECONDITION, plus whatever [_extra] says.
Future<ServerSocket> _server() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc+proto'),
      ]);
      stream.sendHeaders([
        http2.Header.ascii('grpc-status', '9'),
        http2.Header.ascii('grpc-message', 'the precondition failed'),
        ..._extra,
      ], endStream: true);
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

Future<Object?> _callWith(List<http2.Header> extra) async {
  _extra = extra;
  final socket = await _server();
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: socket.port,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await transport.close().catchError((Object _) {});
    await socket.close();
  });

  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 8));
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  // CONTROL. Small details, under every limit. If this ever stops reading 9 the
  // rig never delivers a server status and the witnesses prove nothing.
  test('CONTROL: a status with small details arrives as itself', () async {
    final thrown = await _callWith([
      http2.Header.ascii('grpc-status-details-bin', 'A' * 16),
    ]);

    expect(thrown, isA<RpcStatusException>());
    expect(
      (thrown! as RpcStatusException).statusCode,
      RpcStatus.failedPrecondition,
    );
  });

  // WITNESS. Before the fix: status 3, INVALID_ARGUMENT, naming our own limit.
  test('a status survives details over maxHeaderValueBytes', () async {
    final thrown = await _callWith([
      http2.Header.ascii('grpc-status-details-bin', 'A' * (10 * 1024)),
    ]);

    expect(thrown, isA<RpcStatusException>());
    expect(
      (thrown! as RpcStatusException).statusCode,
      RpcStatus.failedPrecondition,
      reason:
          'our limit on the peer\'s detail header must not replace the status '
          'the server sent -- the application branches on this code',
    );
  });

  // WITNESS, second limit. `maxHeaders` is refused inside the converter's own
  // walk, so there is no metadata to read a status out of by then: this arm is
  // what forces the status to be read from the RAW headers.
  test('a status survives more trailer headers than maxHeaders', () async {
    final thrown = await _callWith([
      for (var i = 0; i < 200; i++) http2.Header.ascii('x-detail-$i', 'v'),
    ]);

    expect(thrown, isA<RpcStatusException>());
    expect(
      (thrown! as RpcStatusException).statusCode,
      RpcStatus.failedPrecondition,
    );
  });

  // GUARD. The connection is not the call: one over-decorated trailer must not
  // take the socket down, or every other call in flight dies with it.
  test('GUARD: the connection survives the violation', () async {
    _extra = [http2.Header.ascii('grpc-status-details-bin', 'A' * (10 * 1024))];
    final socket = await _server();
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await socket.close();
    });

    for (var i = 0; i < 3; i++) {
      try {
        await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // expected: status 9 every time
      }
    }

    expect(transport.isClosed, isFalse);
    expect((await transport.health()).level, RpcHealthLevel.healthy);
  });
}
