// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

// Minimal protobuf binary encoder.
// Only wire types used in descriptor.proto: VARINT (0) and LEN (2).

const int _wireVarint = 0;
const int _wireLen = 2;

/// Minimal protobuf binary encoder for descriptor.proto.
///
/// A byte-identical copy of `_ProtoWriter` lives in `rpc_dart_generator`
/// (lib/src/generator.dart). The two are not merged into one shared class
/// because this package is `publish_to: none` while the generator is published,
/// and a published package may not depend on an unpublished one. Any change
/// here must be mirrored there; a parity test guards that the two produce
/// identical bytes for the same input.
class ProtoWriter {
  final _buf = <int>[];

  void writeVarint(int value) {
    assert(value >= 0);
    while (value > 0x7F) {
      _buf.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    _buf.add(value & 0x7F);
  }

  void _writeTag(int fieldNumber, int wireType) {
    writeVarint((fieldNumber << 3) | wireType);
  }

  void writeString(int fieldNumber, String value) {
    if (value.isEmpty) return;
    final encoded = utf8.encode(value);
    _writeTag(fieldNumber, _wireLen);
    writeVarint(encoded.length);
    _buf.addAll(encoded);
  }

  void writeBytes(int fieldNumber, Uint8List value) {
    if (value.isEmpty) return;
    _writeTag(fieldNumber, _wireLen);
    writeVarint(value.length);
    _buf.addAll(value);
  }

  void writeBool(int fieldNumber, bool value) {
    if (!value) return;
    _writeTag(fieldNumber, _wireVarint);
    writeVarint(1);
  }

  void writeInt32(int fieldNumber, int value) {
    _writeTag(fieldNumber, _wireVarint);
    writeVarint(value);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf);
}
