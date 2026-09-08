// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A FRAMING violation tells the peer it was its fault: 4400 -> UNKNOWN, which
// is NOT retried (5f8667a0). An inbound METADATA POLICY violation is just as
// deterministic and closed with a plain close(), which a WebSocket peer reads
// as 1005 "no status received" -> UNAVAILABLE -> RETRYABLE. So a peer sending a
// header rpc_dart refuses reconnected and sent it again, forever.
//
// Measured against a raw peer:
//
//   before  policy violation : 1005      framing violation : 4400
//   after   policy violation : 4400      framing violation : 4400
//
// The capability was hidden by a wrapper: RpcWebSocketChannel implements
// IRpcChannelProtocolClose, RpcFrameMultiplexedChannel wraps it and did not
// forward it, so RpcChannelTransport could only reach close().

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A byte below 0x20, which `RpcSecurityPolicy.isValidHeaderValue` refuses.
///
/// Built with `fromCharCode`, never written out. A literal control byte is
/// invisible in the source and an escape is easy to lose in an edit; either way
/// the fixture silently becomes a VALID header, the server correctly does not
/// refuse it, and the test asserts nothing. That is not hypothetical — it cost
/// a full round to untangle.
final _controlChar = String.fromCharCode(1);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Uint8List _frame(int streamId, int flags, List<int> payload) {
  final f = Uint8List(9 + payload.length);
  final view = ByteData.sublistView(f);
  view.setUint32(0, streamId);
  view.setUint8(4, flags);
  view.setUint32(5, payload.length);
  f.setRange(9, f.length, payload);
  return f;
}

/// Valid framing, valid JSON, refused by the security policy.
Uint8List _policyViolatingFrame() => _frame(
  1,
  0x02,
  utf8.encode(
    json.encode({
      'p': '/Svc/echo',
      'h': [
        ['x-bad', '${_controlChar}value'],
      ],
    }),
  ),
);

Future<int> _startServer(StreamController<WebSocketChannel> connCtl) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc()..setup()],
    // Set EXPLICITLY: the flag defaults to false since round 190, because one
    // metadata frame with 3000 headers -- inside maxMetadataBytes, so past
    // every size check -- was enough for a peer to end the connection. What
    // this file measures is the close CODE when a deployment does ask to
    // close, and that is unchanged.
    policy: const RpcSecurityPolicy(closeOnProtocolError: true),
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });
  return http.port;
}

/// Sends [bytes] from a RAW peer and returns the close code it observes.
Future<int?> _closeCodeFor(int port, Uint8List bytes) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  final done = Completer<void>();
  ws.listen(
    (_) {},
    onError: (Object _) {},
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  ws.add(bytes);
  await done.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => fail('the server never closed the connection'),
  );
  final code = ws.closeCode;
  await ws.close();
  return code;
}

void main() {
  test(
    'WITNESS: a metadata policy violation is not retryable',
    () async {
      final port = await _startServer(StreamController<WebSocketChannel>());

      expect(
        await _closeCodeFor(port, _policyViolatingFrame()),
        4400,
        reason:
            'the peer was told 1005, which maps to UNAVAILABLE and is retried, '
            'so it will send the same rejected header again',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a framing violation still closes 4400',
    () async {
      // The path this one was aligned WITH must not move.
      final port = await _startServer(StreamController<WebSocketChannel>());

      final oversized = Uint8List(9);
      final view = ByteData.sublistView(oversized);
      view.setUint32(0, 3);
      view.setUint8(4, 0x00);
      view.setUint32(5, 0xFFFFFFFF);

      expect(await _closeCodeFor(port, oversized), 4400);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: the server keeps serving after refusing a peer',
    () async {
      // Closing the offending connection must not take the server with it.
      final connCtl = StreamController<WebSocketChannel>();
      final port = await _startServer(connCtl);

      expect(await _closeCodeFor(port, _policyViolatingFrame()), 4400);

      final client = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:$port'),
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(caller.close);
      final response = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'after'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(response.value, 'after');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a VALID header is not treated as a violation',
    () async {
      // Load-bearing, and the reason the fixture above is built rather than
      // typed: with a printable value the server must NOT close, so a witness
      // written around a mistyped fixture would pass while proving nothing.
      final port = await _startServer(StreamController<WebSocketChannel>());

      final valid = _frame(
        1,
        0x02,
        utf8.encode(
          json.encode({
            'p': '/Svc/echo',
            'h': [
              ['x-ok', 'printable-ascii'],
            ],
          }),
        ),
      );

      final ws = await WebSocket.connect('ws://127.0.0.1:$port');
      final closed = Completer<void>();
      ws.listen(
        (_) {},
        onError: (Object _) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
      ws.add(valid);

      var wasClosed = true;
      await closed.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => wasClosed = false,
      );
      await ws.close();

      expect(
        wasClosed,
        isFalse,
        reason: 'a printable-ASCII header value must not close the connection',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
