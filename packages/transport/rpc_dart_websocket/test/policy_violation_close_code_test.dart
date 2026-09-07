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

Future<int> _startServer(StreamController<WebSocketChannel> connCtl) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc()..setup()],
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

      // Valid framing, valid JSON, refused by isValidHeaderValue: a control
      // character in the value.
      final badValue = _frame(
        1,
        0x02,
        utf8.encode(
          json.encode({
            'p': '/Svc/echo',
            'h': [
              ['x-bad', 'ctrlchar'],
            ],
          }),
        ),
      );

      expect(
        await _closeCodeFor(port, badValue),
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
    'GUARD: an ordinary call is unaffected',
    () async {
      // Load-bearing: closing on a policy violation must not become closing on
      // anything.
      final connCtl = StreamController<WebSocketChannel>();
      final port = await _startServer(connCtl);

      final client = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:$port'),
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(caller.close);

      final response = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hello'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(response.value, 'hello');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
