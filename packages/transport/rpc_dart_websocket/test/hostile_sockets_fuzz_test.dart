// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Gate-sized slices of the P-225 websocket harnesses, from a fixed seed:
//
// - hostile raw clients (handshake variants, WebSocket frames of every kind,
//   frames glued to the handshake, cut-offs) against a real server, with and
//   without compression; a well-formed client must still be served;
// - a hostile raw server (wrong answers to the handshake, then close frames,
//   pings, masked frames, junk) against the client; no connect, call or close
//   may hang.
//
// Nothing may reach the zone in either. The full-length runs are in
// `.dart_tool/probe/fuzz_ws_server.dart` and `fuzz_ws_client.dart`.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

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

Uint8List _wsFrame(Random rnd, {required bool masked, int? opcode}) {
  final op = opcode ?? [0, 1, 2, 2, 8, 9, 10, 3, 15][rnd.nextInt(9)];
  final len = [0, 3, 125, 126, 400][rnd.nextInt(5)];
  final declared = rnd.nextInt(8) == 0
      ? [1, 65536, 1 << 40][rnd.nextInt(3)]
      : len;
  final b = BytesBuilder()
    ..addByte(
      (rnd.nextInt(4) != 0 ? 0x80 : 0) | (rnd.nextInt(12) == 0 ? 0x40 : 0) | op,
    );
  final m = masked ? 0x80 : 0;
  if (declared < 126) {
    b.addByte(m | declared);
  } else if (declared <= 0xffff) {
    b
      ..addByte(m | 126)
      ..add((ByteData(2)..setUint16(0, declared)).buffer.asUint8List());
  } else {
    b
      ..addByte(m | 127)
      ..add((ByteData(8)..setUint64(0, declared)).buffer.asUint8List());
  }
  if (masked) b.add([1, 2, 3, 4]);
  b.add(List.generate(len, (_) => rnd.nextInt(256)));
  return b.takeBytes();
}

String _handshake(Random rnd, int port) {
  final headers = [
    'Host: 127.0.0.1:$port',
    if (rnd.nextInt(10) != 0) 'Upgrade: websocket',
    if (rnd.nextInt(10) != 0) 'Connection: Upgrade',
    if (rnd.nextInt(10) != 0) 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
    if (rnd.nextInt(8) == 0) 'Sec-WebSocket-Key: c2Vjb25kIG5vbmNlIGhlcmU=',
    if (rnd.nextInt(10) != 0)
      'Sec-WebSocket-Version: ${rnd.nextInt(8) == 0 ? 8 : 13}',
    if (rnd.nextInt(6) == 0) 'Sec-WebSocket-Version: 13',
    if (rnd.nextInt(6) == 0) 'Sec-WebSocket-Protocol: a, b',
    if (rnd.nextInt(6) == 0) 'Sec-WebSocket-Extensions: permessage-deflate',
  ]..shuffle(rnd);
  return 'GET / HTTP/1.1\r\n${headers.join('\r\n')}\r\n\r\n';
}

Future<void> _attack(Random rnd, int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  unawaited(socket.done.catchError((Object _) {}));
  socket.listen((_) {}, onError: (Object _) {}, onDone: () {});
  try {
    final hs = utf8.encode(_handshake(rnd, port));
    final frames = [
      for (var i = 0; i < rnd.nextInt(5); i++)
        ..._wsFrame(rnd, masked: rnd.nextInt(6) != 0),
    ];
    if (rnd.nextBool()) {
      socket.add([...hs, ...frames]);
    } else {
      socket.add(hs.sublist(0, rnd.nextInt(hs.length + 1)));
      await socket.flush();
      socket.add(frames);
    }
    await socket.flush().timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(20)));
  } catch (_) {
  } finally {
    socket.destroy();
  }
}

String _accept(String key) => base64Encode(
  sha1.convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes,
);

Future<void> _hostileServe(Random rnd, Socket socket) async {
  unawaited(socket.done.catchError((Object _) {}));
  final buffered = <int>[];
  final header = Completer<String>();
  socket.listen(
    (data) {
      if (header.isCompleted) return;
      buffered.addAll(data);
      final text = latin1.decode(buffered);
      if (text.contains('\r\n\r\n')) header.complete(text);
    },
    onError: (Object _) {},
    onDone: () {},
  );
  try {
    final request = await header.future.timeout(const Duration(seconds: 2));
    final key =
        RegExp(
          r'Sec-WebSocket-Key: (.*)\r',
          caseSensitive: false,
        ).firstMatch(request)?.group(1)?.trim() ??
        '';
    switch (rnd.nextInt(5)) {
      case 0:
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi');
      case 1:
        socket.write(
          'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
          'Connection: Upgrade\r\nSec-WebSocket-Accept: AAAA\r\n\r\n',
        );
      default:
        socket.write(
          'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
          'Connection: Upgrade\r\nSec-WebSocket-Accept: ${_accept(key)}\r\n\r\n',
        );
        for (var i = 0; i < 1 + rnd.nextInt(6); i++) {
          socket.add(_wsFrame(rnd, masked: rnd.nextInt(10) == 0));
          if (rnd.nextBool()) {
            await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(20)));
          }
        }
    }
    await socket.flush();
    await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(100)));
  } catch (_) {
  } finally {
    socket.destroy();
  }
}

void main() {
  for (final compressed in [false, true]) {
    test('hostile clients cannot stop the server '
        '(compression ${compressed ? 'on' : 'off'})', () async {
      final rnd = Random(compressed ? 21 : 22);
      final zone = <Object>[];
      await runZonedGuarded(() async {
        final http = await HttpServer.bind('127.0.0.1', 0);
        final server = RpcWebSocketServer(
          connections: rpcWebSocketConnections(
            http,
            compression: compressed
                ? CompressionOptions.compressionDefault
                : CompressionOptions.compressionOff,
          ),
          onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
        );
        await server.start();
        for (var a = 0; a < 60; a++) {
          await Future.wait([
            for (var k = 0; k < 1 + rnd.nextInt(3); k++)
              _attack(rnd, http.port),
          ]);
        }
        final client = await RpcWebSocketCallerTransport.connect(
          Uri.parse('ws://127.0.0.1:${http.port}'),
        );
        final caller = RpcCallerEndpoint(transport: client);
        final answer = await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'ping'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
        expect(answer.value, 'ping');
        await caller.close();
        await client.close();
        await server.stop();
        await http.close(force: true);
      }, (e, _) => zone.add(e));
      expect(zone, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test(
    'a hostile server cannot hang the client',
    () async {
      final rnd = Random(23);
      final zone = <Object>[];
      await runZonedGuarded(() async {
        final server = await ServerSocket.bind('127.0.0.1', 0);
        server.listen((s) => unawaited(_hostileServe(rnd, s)));
        for (var i = 0; i < 25; i++) {
          RpcWebSocketCallerTransport client;
          try {
            client = await RpcWebSocketCallerTransport.connect(
              Uri.parse('ws://127.0.0.1:${server.port}'),
            ).timeout(const Duration(seconds: 4));
          } on TimeoutException {
            fail('connect hung');
          } catch (_) {
            continue; // a refused connect is a legitimate outcome
          }
          final caller = RpcCallerEndpoint(transport: client);
          final outcome = await caller
              .unaryRequest<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'u',
                request: 'q'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
                context: RpcContext.withTimeout(
                  const Duration(milliseconds: 300),
                ),
              )
              .then((_) => 'value', onError: (Object _) => 'error')
              .timeout(const Duration(seconds: 4), onTimeout: () => 'HUNG');
          expect(outcome, isNot('HUNG'));
          await caller.close().timeout(const Duration(seconds: 4));
          await client.close().timeout(const Duration(seconds: 4));
        }
        await server.close();
      }, (e, _) => zone.add(e));
      expect(zone, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
