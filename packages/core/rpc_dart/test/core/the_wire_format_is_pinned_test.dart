// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The bytes rpc_dart puts on the wire, as literals.
//
// Round-trip tests pass when encoder and decoder change together, and so do
// the two ends of one release. Two ends of different 7.x releases do not: a
// patch that changes a byte here breaks every peer still on an older one. Each
// fixture is checked both ways, so a release keeps writing these bytes and
// keeps reading them.
//
// A failure here is a wire change. It needs a new
// RpcChannelFrame.protocolVersion, not an updated literal.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('channel frames', () {
    test('the preface is "rpcdart" and version 1', () {
      expect(_toHex(RpcChannelFrame.preface), '7270636461727401');
      expect(RpcChannelFrame.protocolVersion, 1);
      expect(RpcChannelFrame.headerSize, 9);
      expect(RpcChannelFrame.flagMetadata, 2);
    });

    const dataFrame = '000000010100000001ab';

    test('a data frame', () {
      final encoded = RpcChannelFrame.encodeData(
        streamId: 1,
        payload: Uint8List.fromList([0xab]),
        endOfStream: true,
      );
      expect(_toHex(encoded), dataFrame);

      final decoded = RpcChannelFrame.decode(_hex(dataFrame))!;
      expect(decoded.streamId, 1);
      expect(decoded.endOfStream, isTrue);
      expect(decoded.isMetadata, isFalse);
      expect(decoded.payload, [0xab]);
    });

    const metadataFrame =
        '0000000302000000220a2f5376632f4563686f02016101620c677270632d74696d65'
        '6f757405313530306d';

    test('a metadata frame with a method path', () {
      final encoded = RpcChannelFrame.encodeMetadata(
        streamId: 3,
        metadata: RpcMetadata([
          RpcHeader('a', 'b'),
          RpcHeader('grpc-timeout', '1500m'),
        ], methodPath: '/Svc/Echo'),
      );
      expect(_toHex(encoded), metadataFrame);

      final decoded = RpcChannelFrame.decode(_hex(metadataFrame))!;
      expect(decoded.streamId, 3);
      expect(decoded.isMetadata, isTrue);
      expect(decoded.endOfStream, isFalse);
      expect(decoded.methodPath, '/Svc/Echo');
      expect(decoded.metadata!.getHeaderValue('a'), 'b');
      expect(decoded.metadata!.getHeaderValue('grpc-timeout'), '1500m');
    });

    const grantFrame =
        '000000000200000021000118782d7270632d636f6e6e2d77696e646f772d75706461'
        '7465053635353336';

    test('a connection window grant on stream 0', () {
      final encoded = RpcChannelFrame.encodeMetadata(
        streamId: 0,
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xConnWindowUpdate, '65536'),
        ]),
      );
      expect(_toHex(encoded), grantFrame);

      final decoded = RpcChannelFrame.decode(_hex(grantFrame))!;
      expect(decoded.methodPath, isNull);
      expect(
        decoded.metadata!.getHeaderValue(RpcHeaders.xConnWindowUpdate),
        '65536',
      );
    });
  });

  test('the gRPC message prefix', () {
    expect(
      _toHex(RpcMessageFrame.encode(Uint8List.fromList([1, 2, 3]))),
      '0000000003010203',
    );
    final header = RpcMessageFrame.parseHeader(_hex('0100000003'));
    expect(header.isCompressed, isTrue);
    expect(header.messageLength, 3);
  });

  const cbor =
      'a5616161786162016562797465734109646c69737483f5f6fb3ff8000000000000636e'
      '656721';

  test('CBOR: types, and keys in a fixed order', () {
    final encoded = CborCodec.encode({
      'b': 1,
      'a': 'x',
      'list': [true, null, 1.5],
      'neg': -2,
      'bytes': Uint8List.fromList([9]),
    });
    expect(_toHex(encoded), cbor);

    final decoded = CborCodec.decode(_hex(cbor));
    expect(decoded['a'], 'x');
    expect(decoded['b'], 1);
    expect(decoded['neg'], -2);
    expect(decoded['list'], [true, null, 1.5]);
    expect(decoded['bytes'], [9]);
  });

  test('grpc-timeout', () {
    expect(
      RpcMetadata.encodeGrpcTimeout(const Duration(milliseconds: 1500)),
      '1500000u',
    );
    expect(RpcMetadata.encodeGrpcTimeout(const Duration(hours: 2)), '7200000m');
    expect(
      RpcMetadata.encodeGrpcTimeout(const Duration(microseconds: 1)),
      '1u',
    );
    for (final (raw, expected) in [
      ('2H', const Duration(hours: 2)),
      ('3M', const Duration(minutes: 3)),
      ('4S', const Duration(seconds: 4)),
      ('1500m', const Duration(milliseconds: 1500)),
      ('7u', const Duration(microseconds: 7)),
      ('5000n', const Duration(microseconds: 5)),
    ]) {
      expect(RpcMetadata.parseGrpcTimeout(raw), expected, reason: raw);
    }
  });

  const statusDetails =
      '080512076d697373696e671a410a28747970652e676f6f676c65617069732e636f6d2f'
      '676f6f676c652e7270632e4572726f72496e666f12150a064e4f5f524f5712026462'
      '1a070a0269641201371a360a28747970652e676f6f676c65617069732e636f6d2f67'
      '6f6f676c652e7270632e5265747279496e666f120a0a0808011080cab5ee01';

  test('grpc-status-details-bin is google.rpc.Status', () {
    final error = RpcStatusException(
      RpcStatus.notFound,
      'missing',
      details: [
        RpcErrorInfo(reason: 'NO_ROW', domain: 'db', metadata: {'id': '7'}),
        RpcRetryInfo(const Duration(milliseconds: 1500)),
      ],
    );
    expect(_toHex(error.statusDetailsBin!), statusDetails);

    final read = RpcStatusException.fromTrailer(
      RpcStatus.notFound,
      'missing',
      detailsBin: _hex(statusDetails),
    );
    final info = read.details.whereType<RpcErrorInfo>().single;
    expect(info.reason, 'NO_ROW');
    expect(info.domain, 'db');
    expect(info.metadata, {'id': '7'});
    expect(
      read.details.whereType<RpcRetryInfo>().single.retryDelay,
      const Duration(milliseconds: 1500),
    );
  });

  String headersOf(RpcMetadata m) =>
      m.headers.map((h) => '${h.name}=${h.value}').join(';');

  test('a status trailer and the cancellation notice', () {
    expect(
      headersOf(RpcTrailers.status(RpcStatus.notFound, message: 'not here')),
      'grpc-status=5;grpc-message=not%20here',
    );
    expect(
      headersOf(RpcTrailers.cancelled('bye')),
      'x-rpc-client-cancelled=true;x-rpc-cancellation-reason=bye;'
      'grpc-status=1',
    );
  });

  test('the control header names and the ping method', () {
    expect(RpcHeaders.xWindowUpdate, 'x-rpc-window-update');
    expect(RpcHeaders.xWindowUpdateMessages, 'x-rpc-window-update-messages');
    expect(RpcHeaders.xConnWindowUpdate, 'x-rpc-conn-window-update');
    expect(RpcHeaders.xClientCancelled, 'x-rpc-client-cancelled');
    expect(RpcHeaders.xCancellationReason, 'x-rpc-cancellation-reason');
    expect(RpcHeaders.xTraceId, 'x-trace-id');
    expect(RpcHeaders.xRequestId, 'x-request-id');
    expect(RpcEndpointPingProtocol.serviceName, '_rpc.System');
    expect(RpcEndpointPingProtocol.methodName, 'Ping');
    expect(
      RpcEndpointPingProtocol.responseTimestampHeader,
      'x-rpc-pong-timestamp',
    );
    expect(
      RpcEndpointPingProtocol.responseDebugLabelHeader,
      'x-rpc-pong-endpoint',
    );
  });
}
