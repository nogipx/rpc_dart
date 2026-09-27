// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The filename happens to be right again. It took three rounds.
//
// B-78: `ensureGrpcFrame`/`frameParsedMessage` decided whether its input was
// already a gRPC frame by PARSING the first five bytes — a heuristic over bytes
// the peer chooses. A body whose first five bytes declared its own remaining
// length was passed through, so the layer above read five of the body's own bytes
// as a header: a 13-byte message arrived as an 8-byte one, silently.
//
// Round 455 removed the guess and broke every compressed message, because with NO
// decompressor — which is what these transports build — `RpcMessageParser` cannot
// de-frame a compressed one and re-frames the payload itself
// (`encode(payload, compressed: true)`), so the guess was load-bearing:
//
//     unconditional framing   grpc-encoding: gzip -> status=13 INTERNAL
//     the heuristic           grpc-encoding: gzip -> OK
//
// Round 461 removed the QUESTION instead. `RpcMessageParser` takes
// `emitFramed: true` and returns a complete frame every time — it knows which
// branch it took, and `frameParsedMessage` is gone. Both rows below are now the
// same rule with no exception:
//
//     a body that looks framed      -> framed   (no bytes lost)
//     a body that cannot look framed -> framed
//
// The compressed path is covered by `identity_case_round_trips_test.dart`.
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

/// The LENGTH of the payload the transport handed upward. Framed is
/// `body.length + 5`; passed through is `body.length`.
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
  // B-78 is FIXED (round 461), and this is the inversion the previous version of
  // this test asked for in so many words: "when B-78 is fixed properly this
  // becomes body.length + 5 and this test should be inverted".
  //
  // Nothing guesses any more. `RpcMessageParser` is built with `emitFramed: true`
  // by these transports, so every value it emits is a complete frame — it knows
  // which branch it took, and the caller never has to ask the bytes.
  test(
    'a body that looks framed is framed anyway',
    () async {
      final body = _selfFramingBody(8);

      expect(
        await _payloadLengthFor(body),
        body.length + 5,
        reason:
            'a body is a body; the parser says whether it framed something, so '
            'no five bytes of an application message can be read as a header',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // The other half of the same decision: a body that CANNOT be mistaken for a
  // frame is framed, which is the ordinary path for every uncompressed message.
  test(
    'a body that cannot look framed is framed',
    () async {
      final body = Uint8List.fromList([0x99, ...List.filled(12, 0xAB)]);

      expect(await _payloadLengthFor(body), body.length + 5);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
