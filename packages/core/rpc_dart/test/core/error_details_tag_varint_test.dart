// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A protobuf field tag is a varint, not a byte. Every decoder in
// error_details.dart read it with `data[offset++]`, which is only correct for
// field numbers 1..15 -- exactly where a tag stops fitting in one byte. Field
// number 16 or higher (a later revision of google.rpc.Status, or any peer that
// emits one) left the continuation byte in the stream: `fieldNumber` came out
// with the 0x80 bit folded in, the wire type was read from the wrong bits, and
// the cursor desynchronised, decoding every field AFTER the unknown one as
// garbage.
//
// Skipping unknown fields and carrying on is the whole point of _skipField and
// of protobuf's forward-compatibility rule, so the loss was silent: details
// went missing rather than erroring.

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Appends a base-128 varint.
void _varint(BytesBuilder b, int v) {
  var x = v;
  while (x >= 0x80) {
    b.addByte((x & 0x7F) | 0x80);
    x = x ~/ 0x80;
  }
  b.addByte(x);
}

/// Appends a length-delimited field (wire type 2) with the given field number.
void _lengthDelimited(BytesBuilder b, int fieldNumber, List<int> payload) {
  _varint(b, fieldNumber * 8 + 2);
  _varint(b, payload.length);
  b.add(payload);
}

/// Appends a varint field (wire type 0).
void _varintField(BytesBuilder b, int fieldNumber, int value) {
  _varint(b, fieldNumber * 8);
  _varint(b, value);
}

void main() {
  test('an unknown high-numbered field is skipped, not desynchronising', () {
    // google.rpc.Status with an unknown field 20 wedged BEFORE the fields we
    // care about. Field 20's tag is 0xA2 0x01 -- two bytes.
    final b = BytesBuilder();
    _varintField(b, 1, 7); // code
    _lengthDelimited(b, 20, utf8.encode('future-field')); // unknown
    _lengthDelimited(b, 2, utf8.encode('boom')); // message
    _lengthDelimited(
      b,
      3,
      RpcErrorInfo(reason: 'QUOTA', domain: 'billing.v1').encodeAsAny(),
    );

    final status = decodeRpcStatus(b.toBytes());

    expect(status.code, 7);
    expect(
      status.message,
      'boom',
      reason: 'a field after the unknown one must still decode',
    );
    expect(status.details, hasLength(1));
    expect((status.details.single as RpcErrorInfo).reason, 'QUOTA');
  });

  test('a high-numbered field inside an Any is skipped', () {
    // ErrorInfo carrying an unknown field 17 before its reason (field 1).
    final inner = BytesBuilder();
    _varintField(inner, 17, 99);
    _lengthDelimited(inner, 1, utf8.encode('QUOTA_EXCEEDED'));
    _lengthDelimited(inner, 2, utf8.encode('billing.v1'));

    final any = BytesBuilder();
    _lengthDelimited(any, 1, utf8.encode(RpcErrorInfo.type));
    _lengthDelimited(any, 2, inner.toBytes());

    final detail = RpcErrorDetail.decodeAny(any.toBytes());

    expect(detail, isA<RpcErrorInfo>());
    expect((detail as RpcErrorInfo).reason, 'QUOTA_EXCEEDED');
    expect(detail.domain, 'billing.v1');
  });

  test('a high-numbered field in Any itself is skipped', () {
    // The Any wrapper's own unknown field 30, before type_url and value.
    final any = BytesBuilder();
    _lengthDelimited(any, 30, utf8.encode('ignored'));
    _lengthDelimited(any, 1, utf8.encode(RpcRetryInfo.type));
    final inner = BytesBuilder();
    final duration = BytesBuilder();
    _varintField(duration, 1, 42); // seconds
    _lengthDelimited(inner, 1, duration.toBytes());
    _lengthDelimited(any, 2, inner.toBytes());

    final detail = RpcErrorDetail.decodeAny(any.toBytes());

    expect(detail, isA<RpcRetryInfo>());
    expect((detail as RpcRetryInfo).retryDelay, const Duration(seconds: 42));
  });

  test('ordinary round trips are unchanged', () {
    // The writer only ever emits fields 1..3, so the common path must be
    // byte-identical to before.
    final encoded = encodeRpcStatus(9, 'nope', [
      RpcBadRequest([
        const RpcFieldViolation(field: 'user.email', description: 'invalid'),
      ]),
      RpcRetryInfo(const Duration(milliseconds: 1500)),
      RpcDebugInfo(stackEntries: const ['a', 'b'], detail: 'ctx'),
    ]);

    final decoded = decodeRpcStatus(Uint8List.fromList(encoded));

    expect(decoded.code, 9);
    expect(decoded.message, 'nope');
    expect(decoded.details, hasLength(3));
    expect(
      (decoded.details[0] as RpcBadRequest).violations.single.field,
      'user.email',
    );
    expect(
      (decoded.details[1] as RpcRetryInfo).retryDelay,
      const Duration(milliseconds: 1500),
    );
    expect((decoded.details[2] as RpcDebugInfo).stackEntries, ['a', 'b']);
  });
}
