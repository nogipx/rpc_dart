// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `ensureGrpcFrame` decided whether a payload was already framed by PARSING its
// first five bytes and checking the declared length against the rest. It is
// called on the OUTPUT of `RpcMessageParser`, which emits de-framed BODIES — so
// the bytes it inspected are an application message body, chosen by the peer.
//
// Any body that happens to look like a frame was returned unchanged, and the
// layer above then read those five bytes as a header. Measured over a real
// socket, same body length in both arms, only the first byte differing:
//
//   body 13B, first byte 0x00 (valid flag)  -> payload 13B, UNCHANGED
//   body 13B, first byte 0x99 (not a flag)  -> payload 18B, re-framed
//
// In the first row a 13-byte message arrived as an 8-byte one, silently.
//
// Whether the input is framed is KNOWN at both call sites, so the guess is gone:
// `frameParsedMessage` frames unconditionally.
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

Uint8List _dataFrame(Uint8List payload, {required int streamId}) =>
    Uint8List.fromList([
      ..._frameHeader(
        length: payload.length,
        type: 0x0,
        flags: 0,
        streamId: streamId,
      ),
      ...payload,
    ]);

/// A body that IS a valid gRPC frame for its own remaining length.
Uint8List _selfFramingBody(int inner) => Uint8List.fromList([
  0,
  (inner >> 24) & 0xFF,
  (inner >> 16) & 0xFF,
  (inner >> 8) & 0xFF,
  inner & 0xFF,
  ...List.filled(inner, 0xAB),
]);

/// A raw server that answers with one message whose BODY is [body], singly
/// framed — what a conforming peer sends.
Future<ServerSocket> _server(Uint8List body) async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  listener.listen((socket) async {
    socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    unawaited(socket.done.catchError((Object _) => socket));
    socket.add(_frameHeader(length: 0, type: 0x4, flags: 0, streamId: 0));
    socket.add(_frameHeader(length: 0, type: 0x4, flags: 0x1, streamId: 0));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 300));

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
    socket.add(_dataFrame(RpcMessageFrame.encode(body), streamId: 1));
    socket.add(
      _headersFrame(
        [_hpackLiteral('grpc-status', '0')],
        streamId: 1,
        endStream: true,
      ),
    );
    await socket.flush();
  });
  return listener;
}

/// The LENGTH of the payload the transport handed upward. Re-framed is
/// `body.length + 5`; returned unchanged is `body.length`.
Future<int> _payloadLengthFor(Uint8List body) async {
  final listener = await _server(body);
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: listener.port,
  );
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await listener.close();
  });

  final lengths = <int>[];
  transport.incomingMessages.listen((m) {
    if (m.payload != null) lengths.add(m.payload!.length);
  });

  final id = transport.createStream();
  await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'M'));
  await transport.sendMessage(
    id,
    RpcMessageFrame.encode(Uint8List(0)),
    endStream: true,
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  expect(lengths, hasLength(1), reason: 'the arm needs exactly one payload');
  return lengths.single;
}

void main() {
  // WITNESS. Before the fix this read 13: the body was handed up unchanged and
  // its first five bytes became a header, turning a 13-byte message into an
  // 8-byte one.
  test(
    'a body that looks like a frame is still framed',
    () async {
      final body = _selfFramingBody(8);

      expect(
        await _payloadLengthFor(body),
        body.length + 5,
        reason:
            'the parser emits de-framed bodies, so this one needs a frame like '
            'any other; guessing from its bytes loses five of them',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL. The same body LENGTH, whose first byte is not a valid compression
  // flag, so the old heuristic could never have fired on it. It read
  // `body + 5` before the fix and must still. If this ever fails, the witness is
  // measuring the harness rather than the heuristic.
  test(
    'CONTROL: a body that cannot look like a frame is unaffected',
    () async {
      final body = Uint8List.fromList([0x99, ...List.filled(12, 0xAB)]);

      expect(await _payloadLengthFor(body), body.length + 5);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
