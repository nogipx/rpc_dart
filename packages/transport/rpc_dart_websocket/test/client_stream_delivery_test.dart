// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Does a client-stream deliver every message, exactly once, in order — on
// dart2js as well as on the VM?
//
// A consumer's production service reports two failures on this path, both
// browser-only: a handler whose FIRST message is really the second one, and a
// batch that arrives short by one message with no error anywhere. The same
// service already carries a server-side deduplicator for a third: every
// message delivered twice.
//
// `websocket_client_stream_no_duplicate_test.dart` covers the duplicate half
// over a real dart:io socket, so it cannot run where the reports come from.
// This file is web-safe — no dart:io — so `-p chrome` puts the same questions
// to dart2js, and it carries the shape the consumer actually sends: several
// concurrent calls of large messages over ONE connection.
@TestOn('vm || browser')
library;

import 'dart:async';

import 'package:async/async.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('one call: every message once, in order', () async {
    final h = await _Harness.start();
    final seen = await h.collect(_texts('a', 8));

    expect(seen, _texts('a', 8), reason: 'handler saw: $seen');
    await h.stop();
  });

  test('one call: 8 large messages arrive whole', () async {
    final h = await _Harness.start();
    final payload = 'x' * (256 * 1024);
    final sent = [for (var i = 0; i < 8; i++) 'b$i:$payload'];
    final seen = await h.collect(sent);

    expect(seen.length, 8, reason: 'lost or duplicated large messages');
    expect(seen, sent);
    await h.stop();
  });

  // The consumer uploads with a concurrency of 4 over one connection. Nothing
  // else in this suite runs more than one client-stream at a time, and the
  // frames of four interleave on a single multiplexed channel.
  test('four concurrent calls do not lose or cross messages', () async {
    final h = await _Harness.start();
    final batches = [for (var k = 0; k < 4; k++) _texts('c$k', 8)];

    final results = await Future.wait([
      for (final batch in batches) h.collect(batch),
    ]);

    for (var k = 0; k < 4; k++) {
      expect(
        results[k],
        batches[k],
        reason: 'call $k saw ${results[k].length} of 8: ${results[k]}',
      );
    }
    await h.stop();
  });

  test('four concurrent calls of large messages', () async {
    final h = await _Harness.start();
    final payload = 'x' * (256 * 1024);
    final batches = [
      for (var k = 0; k < 4; k++)
        [for (var i = 0; i < 8; i++) 'd$k-$i:$payload'],
    ];

    final results = await Future.wait([
      for (final batch in batches) h.collect(batch),
    ]);

    for (var k = 0; k < 4; k++) {
      expect(
        results[k].length,
        8,
        reason: 'call $k saw ${results[k].length} of 8',
      );
      expect(results[k], batches[k]);
    }
    await h.stop();
  });
}

List<String> _texts(String prefix, int n) => [
  for (var i = 0; i < n; i++) '$prefix-$i',
];

/// A caller and a responder joined by an in-memory WebSocket pair — the same
/// plumbing `websocket_web_smoke_test.dart` uses, so it compiles for dart2js.
class _Harness {
  _Harness(this._caller, this._responder, this._service);

  final RpcCallerEndpoint _caller;
  final RpcResponderEndpoint _responder;
  final _CollectingContract _service;

  static Future<_Harness> start() async {
    final (clientWs, serverWs) = _wsPair();
    final caller = RpcCallerEndpoint(
      transport: RpcWebSocketCallerTransport(clientWs),
    );
    final responder = RpcResponderEndpoint(
      transport: RpcWebSocketResponderTransport(serverWs),
    );
    final service = _CollectingContract();
    responder.registerServiceContract(service);
    responder.start();
    return _Harness(caller, responder, service);
  }

  /// Sends [texts] as one client-stream call and returns what the handler saw.
  Future<List<String>> collect(List<String> texts) async {
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
    final id = await response.timeout(const Duration(seconds: 30));
    return _service.byCall[id.value] ?? const [];
  }

  Future<void> stop() async {
    await _caller.close();
    await _responder.close();
  }
}

/// Records each call's messages under an id it returns to the caller, so
/// concurrent calls can be told apart.
final class _CollectingContract extends RpcResponderContract {
  _CollectingContract() : super('Collecting');

  final byCall = <String, List<String>>{};
  var _next = 0;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      handler: (requests, {RpcContext? context}) async {
        final id = 'call-${_next++}';
        final seen = <String>[];
        byCall[id] = seen;
        await for (final r in requests) {
          seen.add(r.value);
        }
        return RpcString(id);
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

/// Two in-memory [WebSocketChannel]s wired back-to-back. No dart:io.
(WebSocketChannel, WebSocketChannel) _wsPair() {
  final clientToServer = StreamController<Object?>();
  final serverToClient = StreamController<Object?>();
  return (
    _MemoryWebSocketChannel(
      incoming: serverToClient.stream,
      outgoing: clientToServer.sink,
    ),
    _MemoryWebSocketChannel(
      incoming: clientToServer.stream,
      outgoing: serverToClient.sink,
    ),
  );
}

class _MemoryWebSocketChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _MemoryWebSocketChannel({
    required Stream<Object?> incoming,
    required StreamSink<Object?> outgoing,
  }) : stream = incoming,
       sink = _MemoryWebSocketSink(outgoing);

  @override
  final Stream<Object?> stream;

  @override
  final WebSocketSink sink;

  @override
  Future<void> get ready async {}

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _MemoryWebSocketSink extends DelegatingStreamSink<Object?>
    implements WebSocketSink {
  _MemoryWebSocketSink(super.sink);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => super.close();
}
