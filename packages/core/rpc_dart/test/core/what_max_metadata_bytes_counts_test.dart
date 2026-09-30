// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `maxMetadataBytes` is enforced in two places that count different things, and
// the field's name says neither: `validateMetadata` totals header name and value
// TEXT, while a transport bounds its own ENCODED form. Which quantity the field
// names was an open question (B-209) until it was measured — there is no single
// answer, because each wire frames the text differently and the JSON form expands
// by the CONTENT of a value rather than its length.
//
// So the field bounds TEXT, deliberately, and this pins that: the text count can
// only ever refuse LATER than a wire would, never earlier. A change that made
// `validateMetadata` count an encoded size would refuse metadata this accepts, on
// a transport that may not even use that encoding.
//
// The measurements are in `.claude/loop/rounds/544`.

import 'package:rpc_dart/rpc_dart.dart';
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
  test(
    'the bound counts TEXT, so a value that EXPANDS when encoded is accepted',
    () {
      // A quote is printable ASCII, so the policy permits it and the JSON encoder
      // must escape every one — the expansion is per character and unbounded by
      // anything the text count can see.
      final expanding = RpcMetadata([
        RpcHeader('h', '"' * 100),
      ], methodPath: '/S/M');

      final text = _textBytes(expanding);
      final encoded = _encodedBytes(expanding);

      // The premise: this metadata straddles the limit — under it as text, over it
      // encoded. Without this the test would pass on any limit at all.
      final policy = RpcSecurityPolicy(maxMetadataBytes: (text + encoded) ~/ 2);
      expect(
        text,
        lessThan(policy.maxMetadataBytes),
        reason: 'the premise: under the limit as text',
      );
      expect(
        encoded,
        greaterThan(policy.maxMetadataBytes),
        reason: 'the premise: over the limit once encoded',
      );

      expect(
        () => policy.validateMetadata(expanding),
        returnsNormally,
        reason: 'the field counts text, and every wire frames it on top',
      );
    },
  );

  test('the bound counts text and NOTHING per header, however many there are', () {
    // The second way to make this field "mean the wire": add a fixed framing
    // charge per header. It is invisible on one large header and dominant on many
    // small ones, so only this shape can see it — the arm above cannot, and a
    // canary proved it could not.
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
  });

  test('GUARD the same text length WITHOUT expansion is accepted too', () {
    // The control: if the arm above passed because the policy accepts everything,
    // this would be indistinguishable from it.
    final plain = RpcMetadata([RpcHeader('h', 'x' * 100)], methodPath: '/S/M');

    expect(
      _encodedBytes(plain),
      lessThan(_encodedBytes(RpcMetadata([RpcHeader('h', '"' * 100)]))),
      reason: 'the same text length, and the plain one encodes smaller',
    );
    expect(
      () => const RpcSecurityPolicy(
        maxMetadataBytes: 200,
      ).validateMetadata(plain),
      returnsNormally,
    );
  });

  test('GUARD the TEXT total is still enforced', () {
    // The bound has to bind, or the first arm says nothing.
    final tooBig = RpcMetadata([
      for (var i = 0; i < 8; i++) RpcHeader('h$i', 'v' * 64),
    ], methodPath: '/S/M');

    expect(
      () => const RpcSecurityPolicy(
        maxMetadataBytes: 100,
      ).validateMetadata(tooBig),
      throwsA(isA<RpcMetadataViolation>()),
    );
  });
}
