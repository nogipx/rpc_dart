// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// When the server answers and ends FIRST -- which a server may do at any point in
// a client-stream upload -- the client's request side was never ended or reset.
// `onDone` removes the id from `_activeStreams`, so `releaseStreamId`'s RST branch
// cannot fire and `finishSending` returns early with nothing to work on.
//
// The cost is entirely at the PEER, which is why nothing here caught it: measured
// against a server answering before the client half-closed, 3 of 3 streams stayed
// half-open at the server while every per-stream map on this side read 0.
//
//     witness, 3 calls   incoming side ENDED 0 of 3
//     control, 3 calls that half-close with the request   3 of 3
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _accepted = 0;
var _incomingEnded = 0;

/// Answers in full as soon as the first DATA frame arrives, without waiting for
/// the client to half-close. `onDone` on the server's incoming side IS the
/// observable: it fires when the client ends its half, and not otherwise.
Future<ServerSocket> _answerEarlyServer() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      _accepted++;
      var answered = false;
      stream.incomingMessages.listen(
        (m) {
          if (m is http2.DataStreamMessage && !answered) {
            answered = true;
            stream.sendHeaders([
              http2.Header.ascii(':status', '200'),
              http2.Header.ascii('content-type', 'application/grpc+proto'),
            ]);
            stream.sendData(
              RpcMessageFrame.encode(
                _codec.serialize('early'.rpc),
                compressed: false,
              ),
            );
            stream.sendHeaders([
              http2.Header.ascii('grpc-status', '0'),
            ], endStream: true);
          }
        },
        onDone: () => _incomingEnded++,
        onError: (Object _) {},
      );
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

/// Runs [calls] uploads and returns (accepted, endedAtServer), read BEFORE the
/// teardown: `close()` terminates whatever the transport still tracks, so counts
/// taken after it measure the teardown rather than the calls.
Future<(int, int)> _upload({required bool halfCloseWithRequest}) async {
  _accepted = 0;
  _incomingEnded = 0;
  final socket = await _answerEarlyServer();
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: socket.port,
  );
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await socket.close();
  });

  for (var i = 0; i < 3; i++) {
    final id = transport.createStream();
    await transport.sendMetadata(
      id,
      RpcMetadata.forClientRequest('Svc', 'Upload'),
    );
    await transport.sendMessage(
      id,
      RpcMessageFrame.encode(_codec.serialize('part'.rpc)),
      endStream: halfCloseWithRequest,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    // What the pipeline does when a call ends.
    transport.releaseStreamId(id);
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  return (_accepted, _incomingEnded);
}

void main() {
  // WITNESS. Before the fix this read (3, 0).
  test('our half closes when the server ends the response first', () async {
    final (accepted, ended) = await _upload(halfCloseWithRequest: false);

    expect(
      accepted,
      3,
      reason: 'the three uploads must have reached the server',
    );
    expect(
      ended,
      3,
      reason:
          'a stream left half-open at the peer holds a '
          'MAX_CONCURRENT_STREAMS slot for the life of the connection, and '
          'nothing on this side can see it',
    );
  });

  // CONTROL. The client half-closes with its request, as a unary call does, so
  // the server's incoming side ends for a reason that has nothing to do with the
  // fix. If this ever reads 0 the observable is blind and the witness is empty.
  test(
    'CONTROL: a request that half-closes itself ends the server side',
    () async {
      final (accepted, ended) = await _upload(halfCloseWithRequest: true);

      expect(accepted, 3);
      expect(ended, 3);
    },
  );
}
