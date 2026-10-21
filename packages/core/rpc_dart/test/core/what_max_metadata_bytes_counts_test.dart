// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `maxMetadataBytes` is enforced in two places that count different things, and
// the field's name says neither: `validateMetadata` totals header name and value
// TEXT, while a transport bounds its own ENCODED form. Each wire frames the text
// differently, so there is no single encoded size to count.
//
// So the field bounds TEXT, deliberately, and this pins that: the text count can
// only ever refuse LATER than a wire would, never earlier. A change that made
// `validateMetadata` count an encoded size would refuse metadata this accepts, on
// a transport that may not even use that encoding.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// What `validateMetadata` totals.
int _textBytes(RpcMetadata m) {
  var total = 0;
  for (final h in m.headers) {
    total += h.name.length + h.value.length;
  }
  return total;
}

/// What a frame channel puts on the wire, from the library's OWN encoder rather
/// than a copy of it here — a re-implementation would measure this file instead.
int _encodedBytes(RpcMetadata m) =>
    RpcChannelFrame.encodeMetadata(streamId: 1, metadata: m).length -
    RpcChannelFrame.headerSize;

void main() {
  test('a frame channel encodes a value byte for byte, whatever it holds', () {
    // Printable ASCII is what the policy admits, and the channel frame writes
    // it as is: what a value holds does not change what it costs on the wire.
    final quoted = RpcMetadata([
      RpcHeader('h', r'"\' * 50),
    ], methodPath: '/S/M');
    final plain = RpcMetadata([RpcHeader('h', 'x' * 100)], methodPath: '/S/M');
    expect(_encodedBytes(quoted), _encodedBytes(plain));
  });

  test(
    'the bound counts text and NOTHING per header, however many there are',
    () {
      // The way to make this field "mean the wire": add a fixed framing charge
      // per header. It is invisible on one large header and dominant on many
      // small ones, so only this shape can see it.
      final many = RpcMetadata([
        for (var i = 0; i < 64; i++) RpcHeader('h$i', 'v' * 8),
      ], methodPath: '/S/M');

      final text = _textBytes(many);
      final encoded = _encodedBytes(many);

      // Just above the text total, far below the encoded one: the gap is entirely
      // per-header framing.
      final policy = RpcSecurityPolicy(maxMetadataBytes: text + 4);
      expect(
        encoded,
        greaterThan(policy.maxMetadataBytes),
        reason: 'the premise: the framing alone carries this over the limit',
      );

      expect(
        () => policy.validateMetadata(many),
        returnsNormally,
        reason:
            'a per-header surcharge would refuse this, and which surcharge is '
            'right differs by transport',
      );
    },
  );

  test('GUARD the TEXT total is still enforced', () {
    // The bound has to bind, or the arm above says nothing.
    final tooBig = RpcMetadata([
      for (var i = 0; i < 8; i++) RpcHeader('h$i', 'v' * 64),
    ], methodPath: '/S/M');

    expect(
      () => const RpcSecurityPolicy(
        maxMetadataBytes: 100,
      ).validateMetadata(tooBig),
      throwsA(isA<RpcMetadataViolationException>()),
    );
  });
}
