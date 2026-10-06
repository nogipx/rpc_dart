// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding C2. RpcSecurityPolicy.maxMetadataBytes documented itself as
// "max encoded metadata payload size for transports that serialize metadata
// (for example, JSON over WebSocket)" -- which is exactly what the frame
// channel does -- but nothing read the field. Metadata was bounded only by
// maxMessageLengthBytes, i.e. 16MB where the policy declared 64KB.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A channel whose inbound bytes the test writes by hand: this library's own
/// sender refuses the frames the receiver's limit is tested with.
final class _Pipe implements IRpcChannel {
  final _ctl = StreamController<Uint8List>();

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }

  void feed(Uint8List chunk) => _ctl.add(chunk);
}

// Metadata capped far below the data-payload cap, as the defaults are.
const _policy = RpcSecurityPolicy(
  maxMessageLengthBytes: 1024 * 1024,
  maxMetadataBytes: 2048,
  closeOnProtocolError: false,
);

// ~15KB of headers: well under maxMessageLengthBytes, well over
// maxMetadataBytes.
final _oversized = RpcMetadata([
  for (var i = 0; i < 300; i++) RpcHeader('h$i', 'v' * 40),
], methodPath: '/S/M');

void main() {
  test('an oversized metadata frame is rejected at its own limit', () async {
    final pipe = _Pipe();
    final server = RpcFrameMultiplexedChannel(channel: pipe, policy: _policy);

    final errors = <Object>[];
    server.incoming.listen((_) {}, onError: errors.add);

    // Before the fix this sailed through.
    pipe.feed(
      RpcChannelFrame.encodeMetadata(streamId: 1, metadata: _oversized),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(errors, hasLength(1));
    expect(
      errors.single,
      isA<RpcFrameException>().having(
        (e) => e.message,
        'message',
        contains('metadata frame too large'),
      ),
    );

    await server.close();
  });

  test('the sender refuses the same frame before it leaves', () async {
    final (peer, server) = RpcFrameMultiplexedChannel.pair(policy: _policy);

    await expectLater(
      peer.send(
        RpcTransportMessage.withMetadata(metadata: _oversized, streamId: 1),
      ),
      throwsA(isA<RpcMetadataViolation>()),
    );

    await peer.close();
    await server.close();
  });

  test('a large DATA frame under the payload cap still passes', () async {
    // The metadata cap must not constrain data payloads.
    const policy = RpcSecurityPolicy(
      maxMessageLengthBytes: 1024 * 1024,
      maxMetadataBytes: 2048,
    );
    final (peer, server) = RpcFrameMultiplexedChannel.pair(policy: policy);

    final got = <RpcTransportMessage>[];
    final errors = <Object>[];
    server.incoming.listen(got.add, onError: errors.add);

    await peer.send(
      RpcTransportMessage.withPayload(
        payload: Uint8List(64 * 1024),
        streamId: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(errors, isEmpty);
    expect(got, hasLength(1));
    expect(got.single.payload, hasLength(64 * 1024));

    await peer.close();
    await server.close();
  });

  test('ordinary metadata is unaffected by the default policy', () async {
    final (peer, server) = RpcFrameMultiplexedChannel.pair();

    final got = <RpcTransportMessage>[];
    final errors = <Object>[];
    server.incoming.listen(got.add, onError: errors.add);

    await peer.send(
      RpcTransportMessage.withMetadata(
        metadata: RpcMetadata.forClientRequest('Svc', 'method'),
        streamId: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(errors, isEmpty);
    expect(got.single.methodPath, '/Svc/method');

    await peer.close();
    await server.close();
  });
}
