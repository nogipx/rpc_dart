// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// **THE FILENAME IS WRONG AND CANNOT BE CHANGED HERE** (`mv` is outside the
// loop's allowlist). It says "a self-framing body is still framed", which is what
// round 455 asserted and round 457 had to undo. Rename it to
// `a_framed_payload_passes_through_test.dart` when convenient.
//
// What this file now characterises is a DEFECT that is still open (B-78), and why
// it cannot simply be removed.
//
// `frameParsedMessage` decides whether its input is already a gRPC frame by
// PARSING the first five bytes. That is a heuristic over bytes the peer chose, and
// round 455 measured the damage: a body whose first five bytes happen to declare
// its own remaining length is passed through, so the layer above reads five of the
// body's own bytes as a header — a 13-byte message arrives as an 8-byte one,
// silently.
//
// Round 455 removed the heuristic. That was WRONG, and round 457 measured why:
// these transports build their parser with NO decompressor, so for a COMPRESSED
// message `RpcMessageParser` cannot de-frame — it re-frames the compressed payload
// itself (`encode(payload, compressed: true)`, parser.dart:218) precisely so the
// layer above can decompress it. Framing that again loses the compressed bit:
//
//     unconditional framing   grpc-encoding: gzip -> status=13 INTERNAL
//     the heuristic           grpc-encoding: gzip -> OK
//
// So the guess is load-bearing until the parser TELLS its caller which branch it
// took. Both behaviours below are asserted so the trade is visible: the pass-through
// that compression needs, and the same pass-through misfiring on an application body.
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
  // CHARACTERISES B-78, which is OPEN. A body indistinguishable from a frame is
  // passed through, and five of its bytes become a header. This is not the
  // behaviour anyone wants; it is the price of the pass-through that compression
  // needs, and it is asserted so the day the parser carries the fact, this test
  // fails and points at B-78.
  test(
    'KNOWN DEFECT (B-78): a body that looks framed is passed through',
    () async {
      final body = _selfFramingBody(8);

      expect(
        await _payloadLengthFor(body),
        body.length,
        reason:
            'the heuristic cannot tell this body from a compressed message the '
            'parser already re-framed; when B-78 is fixed properly this becomes '
            'body.length + 5 and this test should be inverted',
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
