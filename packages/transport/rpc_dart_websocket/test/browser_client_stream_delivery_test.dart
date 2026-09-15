// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The browser half of the B-44 bench: a REAL browser WebSocket against a real
// dart:io server, which is the one combination the suite has never covered and
// the only one the field failures come from.
//
// The server is a separate process — a browser test cannot bind a socket:
//
//   fvm dart run .dart_tool/probes/ws_collect_server.dart 9531
//   fvm dart test test/browser_client_stream_delivery_test.dart -p chrome
//
// The handler answers `count|head,head,...` of what it received, so every
// assertion here is on the response: no control channel, nothing to trust but
// the wire.
@TestOn('browser')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _url = 'ws://localhost:9531';

void main() {
  test('one call, 8 small messages', () async {
    final c = await _connect();
    final r = await c.collect(_texts('a', 8));
    expect(r.count, 8, reason: r.raw);
    expect(r.heads, _texts('a', 8));
    await c.close();
  });

  // The shape the consumer sends: 256 KiB frames, which is where the
  // multiplexer has to split and reassemble.
  test('one call, 8 x 256KiB messages', () async {
    final c = await _connect();
    final r = await c.collect(_big('b', 8));
    expect(r.count, 8, reason: r.raw);
    await c.close();
  });

  // Four concurrent calls on ONE connection — the consumer's upload
  // concurrency, and the thing no existing test does.
  test('four concurrent calls, 8 x 256KiB each', () async {
    final c = await _connect();
    final results = await Future.wait([
      for (var k = 0; k < 4; k++) c.collect(_big('c$k', 8)),
    ]);
    for (var k = 0; k < 4; k++) {
      expect(results[k].count, 8, reason: 'call $k: ${results[k].raw}');
    }
    await c.close();
  });

  // Repeated: the field failure is intermittent per connection, so one clean
  // pass proves less than a run of them.
  test('twenty sequential calls on one connection', () async {
    final c = await _connect();
    final short = <String>[];
    for (var i = 0; i < 20; i++) {
      final r = await c.collect(_big('d$i', 4));
      if (r.count != 4) short.add('call $i saw ${r.count}');
    }
    expect(short, isEmpty);
    await c.close();
  });

  // A cold connection per call, which is where the consumer's notes put the
  // fault ("the first ~2 streams after a cold connect").
  test('ten cold connections, one call each', () async {
    final short = <String>[];
    for (var i = 0; i < 10; i++) {
      final c = await _connect();
      final r = await c.collect(_big('e$i', 4));
      if (r.count != 4) short.add('connect $i saw ${r.count}: ${r.raw}');
      await c.close();
    }
    expect(short, isEmpty);
  });
}

List<String> _texts(String prefix, int n) => [
  for (var i = 0; i < n; i++) '$prefix-$i',
];

/// 256 KiB messages whose first 12 characters identify them, because that is
/// all the handler echoes back.
List<String> _big(String prefix, int n) => [
  for (var i = 0; i < n; i++)
    '$prefix-$i'.padRight(12, '.') + ('x' * (256 * 1024)),
];

Future<_Client> _connect() async {
  final ws = WebSocketChannel.connect(Uri.parse(_url));
  await ws.ready;
  final caller = RpcCallerEndpoint(transport: RpcWebSocketCallerTransport(ws));
  return _Client(caller);
}

class _Client {
  _Client(this._caller);
  final RpcCallerEndpoint _caller;

  Future<({int count, List<String> heads, String raw})> collect(
    List<String> texts,
  ) async {
    final call = _caller.clientStream<RpcString, RpcString>(
      serviceName: 'Collecting',
      methodName: 'Collect',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    final requests = StreamController<RpcString>();
    final response = call(requests.stream);
    for (final t in texts) {
      requests.add(RpcString(t));
    }
    await requests.close();
    final raw = (await response.timeout(const Duration(seconds: 30))).value;
    final parts = raw.split('|');
    return (
      count: int.parse(parts.first),
      heads: parts.length > 1 && parts[1].isNotEmpty
          ? parts[1].split(',')
          : <String>[],
      raw: raw,
    );
  }

  Future<void> close() => _caller.close();
}
