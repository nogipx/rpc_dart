// Many client-streams on one connection, several at a time — in dart2js.
//
// The VM does this cleanly (120 calls, 4 concurrent, nothing lost). Production
// is the browser, and it loses the OPENING message of a call and sometimes all
// of them. This is the same shape on the engine that shows the fault.
@TestOn('browser')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _url = 'ws://localhost:9532';
const _frameBytes = 256 * 1024;

void main() {
  test(
    '60 calls of 8 frames, 4 at a time, one connection',
    () async {
      final ws = WebSocketChannel.connect(Uri.parse(_url));
      await ws.ready;
      final caller = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(ws),
      );
      final filler = 'x' * (_frameBytes - 12);
      final bad = <String>[];

      Future<void> one(int n) async {
        final call = caller.clientStream<RpcString, RpcString>(
          serviceName: 'Collecting',
          methodName: 'Collect',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
        );
        final requests = StreamController<RpcString>();
        final response = call(requests.stream);
        for (var i = 0; i < 8; i++) {
          requests.add(RpcString('f:$i'.padRight(12, '.') + filler));
        }
        await requests.close();
        final raw = (await response.timeout(const Duration(seconds: 60))).value;
        final parts = raw.split('|');
        if (parts[0] != '8' || parts[1] != '0') bad.add('call $n: $raw');
      }

      var launched = 0;
      while (launched < 60) {
        final batch = <Future<void>>[];
        for (var k = 0; k < 4 && launched < 60; k++, launched++) {
          batch.add(one(launched));
        }
        await Future.wait(batch);
      }

      expect(bad, isEmpty, reason: '${bad.length} of 60 calls lost frames');
      await caller.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
