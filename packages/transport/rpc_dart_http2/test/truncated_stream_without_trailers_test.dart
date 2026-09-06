// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server stream cut off by END_STREAM on a DATA frame, with no trailers, read
// as a CLEAN END -- silent data loss. A client paging results believed it had
// them all.
//
// In gRPC over HTTP/2 the status travels in trailers (a HEADERS frame with
// END_STREAM), so DATA never legitimately carries END_STREAM. When a peer ends
// the stream on DATA the response is malformed, and the transport's `onDone`
// already synthesised an UNAVAILABLE saying so -- but the data path had
// propagated END_STREAM first, closing the consumer's stream before that error
// could be delivered. Traced against a raw server sending two messages then
// END_STREAM with no trailers:
//
//   [transport] payload=true  end=true  grpc-status=-    <- closes the stream
//   [transport] payload=false end=true  grpc-status=14   <- error, too late
//   consumer: CLEAN END after 2 item(s), no error raised
//
// This is the same failure 1a38a156 fixed for a connection that DIES;
// `_statusReceived` was added then, but the end-of-stream flag on the data path
// short-circuited it for a peer that half-closes instead.
//
// Found by re-measuring a DEFERRED decision ("half-close with no grpc-status"),
// whose recorded premise turned out to be stale.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

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

/// HPACK literal header field without indexing, new name, no Huffman.
List<int> _hpackLiteral(String name, String value) {
  final n = ascii.encode(name);
  final v = ascii.encode(value);
  return [0x00, n.length, ...n, v.length, ...v];
}

Uint8List _headersFrame(
  List<List<int>> headers, {
  required int streamId,
  required bool endStream,
}) {
  final block = <int>[for (final h in headers) ...h];
  return Uint8List.fromList([
    ..._frameHeader(
      length: block.length,
      type: 0x1,
      flags: 0x4 | (endStream ? 0x1 : 0x0),
      streamId: streamId,
    ),
    ...block,
  ]);
}

Uint8List _dataFrame(
  Uint8List payload, {
  required int streamId,
  required bool endStream,
}) => Uint8List.fromList([
  ..._frameHeader(
    length: payload.length,
    type: 0x0,
    flags: endStream ? 0x1 : 0x0,
    streamId: streamId,
  ),
  ...payload,
]);

/// A raw HTTP/2 server that answers with [messages] items and then ends the
/// stream in the way [withTrailers] selects.
Future<ServerSocket> _rawServer({required bool withTrailers}) async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  listener.listen((socket) async {
    socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    socket.done.catchError((Object _) => socket);

    socket.add(_frameHeader(length: 0, type: 0x4, flags: 0, streamId: 0));
    socket.add(_frameHeader(length: 0, type: 0x4, flags: 0x1, streamId: 0));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    socket.add(
      _headersFrame(
        [
          _hpackLiteral(':status', '200'),
          _hpackLiteral('content-type', 'application/grpc'),
        ],
        streamId: 1,
        endStream: false,
      ),
    );
    final body = RpcMessageFrame.encode(
      const RpcCodec(RpcNull.fromJson).serialize(const RpcNull()),
    );
    socket.add(_dataFrame(body, streamId: 1, endStream: false));

    if (withTrailers) {
      // Conforming: last DATA without END_STREAM, then trailers carrying it.
      socket.add(_dataFrame(body, streamId: 1, endStream: false));
      socket.add(
        _headersFrame(
          [_hpackLiteral('grpc-status', '0')],
          streamId: 1,
          endStream: true,
        ),
      );
    } else {
      // Malformed: END_STREAM on DATA, no trailers, no status.
      socket.add(_dataFrame(body, streamId: 1, endStream: true));
    }
    await socket.flush();
  });
  return listener;
}

Future<String> _drain(int port) async {
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: port,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  var received = 0;
  try {
    await for (final _
        in caller
            .serverStream<RpcNull, RpcNull>(
              serviceName: 'svc',
              methodName: 'M',
              request: const RpcNull(),
              requestCodec: const RpcCodec(RpcNull.fromJson),
              responseCodec: const RpcCodec(RpcNull.fromJson),
            )
            .timeout(const Duration(seconds: 10))) {
      received++;
    }
    await transport.close().catchError((Object _) {});
    return 'clean end after $received';
  } catch (e) {
    await transport.close().catchError((Object _) {});
    return e is RpcStatusException
        ? 'status ${e.statusCode} after $received'
        : '${e.runtimeType} after $received';
  }
}

void main() {
  test(
    'a stream ended on DATA without trailers is an error, not a clean end',
    () async {
      final listener = await _rawServer(withTrailers: false);
      addTearDown(() => listener.close());

      expect(
        await _drain(listener.port),
        'status ${RpcStatus.unavailable} after 2',
        reason:
            'reporting a clean end here hands the consumer partial data as if '
            'it were complete -- a client paging results believes it has all '
            'of them',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a conforming stream with trailers still ends cleanly',
    () async {
      // The load-bearing guard: end-of-stream now waits for a status, so a
      // well-formed response must still terminate -- otherwise every server
      // stream would hang.
      final listener = await _rawServer(withTrailers: true);
      addTearDown(() => listener.close());

      expect(await _drain(listener.port), 'clean end after 2');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
