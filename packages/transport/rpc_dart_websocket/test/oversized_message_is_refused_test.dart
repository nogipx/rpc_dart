// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Where the ceiling on an inbound WebSocket message actually lives.
//
// RpcSecurityPolicy carried a maxWebSocketMessageBytes that nothing read. It
// was removed in favour of the limit that does the work -- but "does the work"
// was a claim in a doc comment until this file, and doc comments in this repo
// have been wrong before. Measured with maxWebSocketMessageBytes: 1 MiB still
// set, before it was removed:
//
//   four 15 MiB messages -> all accepted, connection still open
//
// a 15x gap between the configured belief and the real bound. The real bound is
// maxMessageLengthBytes, and the frame layer applies it TWICE, which the close
// reason names:
//
//   64 MiB message -> 4400 "Incoming frame buffer overflow: 67108864 bytes
//                     (max: 16777230)"   -- the reassembly cap in
//                     RpcFrameMultiplexedChannel._onData, checked before the
//                     append so nothing oversized is even allocated
//   8 MiB x 3      -> accepted, connection open
//
// The second line of defence is RpcChannelFrame's per-frame maxPayloadLen. The
// two are REDUNDANT, which matters for anyone canarying this file: disabling
// either one alone leaves every test green, because the other still closes the
// connection with the same 4400. Both have to go for the witnesses to fail.
//
// The peak allocation itself cannot be helped: dart:io buffers a whole
// WebSocket message before delivering it, so the bytes are resident before
// rpc_dart sees a byte. What matters is that the connection CLOSES, because a
// connection that survives lets one peer repeat that peak as often as it likes.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (request, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A well-formed 9-byte channel frame header declaring the rest as payload.
Uint8List _framed(int bytes) {
  final data = Uint8List(bytes);
  final view = ByteData.view(data.buffer);
  view.setUint32(0, 1);
  data[4] = 0;
  view.setUint32(5, bytes - RpcChannelFrame.headerSize);
  return data;
}

typedef _Rig = ({HttpServer http, RpcWebSocketServer server});

Future<_Rig> _serve({required int maxMessageBytes}) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http),
    policy: RpcSecurityPolicy(maxMessageLengthBytes: maxMessageBytes),
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    await http.close(force: true);
  });
  return (http: http, server: server);
}

/// Sends [count] messages of [bytes] and reports the close code, or null if the
/// connection was still open at the end.
Future<int?> _push(_Rig rig, {required int bytes, int count = 1}) async {
  final socket = await WebSocket.connect('ws://127.0.0.1:${rig.http.port}');
  socket.listen((_) {}, onError: (Object _) {}, onDone: () {});
  for (var i = 0; i < count; i++) {
    if (socket.readyState != WebSocket.open) break;
    socket.add(_framed(bytes));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final code = socket.readyState == WebSocket.open ? null : socket.closeCode;
  await socket.close();
  return code;
}

Future<String> _stillServing(_Rig rig) async {
  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${rig.http.port}'),
  );
  final caller = RpcCallerEndpoint(transport: client);
  try {
    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'ping',
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

void main() {
  test('a message over maxMessageLengthBytes closes the connection', () async {
    // 4400 is the framing-violation code, which maps to UNKNOWN and is NOT
    // retried -- so the peer stops resending what got it disconnected.
    final rig = await _serve(maxMessageBytes: 1024 * 1024);
    expect(await _push(rig, bytes: 8 * 1024 * 1024), 4400);
  });

  test('the refusal names the limit it hit', () async {
    // Without this the tests above pass for any reason the connection happens
    // to die -- and one earlier version of them was in fact measuring
    // maxMessagesPerChunk, not the size cap, because 8 MiB of zeros decodes
    // into ~1.6M empty gRPC messages. A refusal is only evidence if it names
    // the control under test.
    final rig = await _serve(maxMessageBytes: 1024 * 1024);
    final socket = await WebSocket.connect('ws://127.0.0.1:${rig.http.port}');
    socket.listen((_) {}, onError: (Object _) {}, onDone: () {});
    socket.add(_framed(8 * 1024 * 1024));
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(socket.closeReason, contains('frame buffer overflow'));
    await socket.close();
  });

  test('and the server keeps serving everyone else', () async {
    final rig = await _serve(maxMessageBytes: 1024 * 1024);
    await _push(rig, bytes: 8 * 1024 * 1024);
    expect(await _stillServing(rig), 'pong');
  });

  test('the peer cannot repeat the peak on one connection', () async {
    // The number that matters. The bytes are resident before rpc_dart sees them
    // -- dart:io buffers a whole message -- so the only lever is refusing to
    // let it happen twice.
    final rig = await _serve(maxMessageBytes: 1024 * 1024);
    expect(
      await _push(rig, bytes: 8 * 1024 * 1024, count: 5),
      4400,
      reason: 'a surviving connection is an unlimited supply of peaks',
    );
  });

  test('GUARD: a message under the limit is accepted', () async {
    // Load-bearing: without it, "closes the connection" would also pass for a
    // transport that refused everything.
    final rig = await _serve(maxMessageBytes: 16 * 1024 * 1024);
    expect(
      await _push(rig, bytes: 4 * 1024 * 1024, count: 3),
      isNull,
      reason: 'three legal messages must not close the connection',
    );
  });

  test('GUARD: the ceiling follows the policy, not a constant', () async {
    // The same 8 MiB message that was refused above, against a server that
    // allows it. This is what proves the tests observe maxMessageLengthBytes
    // and not some fixed internal bound.
    final rig = await _serve(maxMessageBytes: 32 * 1024 * 1024);
    expect(await _push(rig, bytes: 8 * 1024 * 1024), isNull);
  });
}
