// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire types this library reads and writes.
abstract final class RpcProtoWireType {
  /// `int32`, `int64`, `uint*`, `bool`, `enum`.
  static const int varint = 0;

  /// `fixed64`, `sfixed64`, `double`.
  static const int fixed64 = 1;

  /// `string`, `bytes`, embedded messages, packed repeated fields.
  static const int lengthDelimited = 2;

  /// `fixed32`, `sfixed32`, `float`.
  static const int fixed32 = 5;
}

/// Reads protobuf wire format from [bytes], one field at a time.
///
/// Every malformed input throws [FormatException]: a truncated or overlong
/// varint, a field that runs past the buffer, a group wire type. Unknown
/// fields are skipped with [skip], as protobuf's forward-compatibility rule
/// requires.
///
/// Exact on the web: varints are accumulated in 32-bit halves, so values past
/// 2^32 and negative `int32`/`int64` (ten bytes of two's complement) decode the
/// same under dart2js as on the VM.
final class RpcProtoReader {
  /// Reads from the start of [bytes].
  RpcProtoReader(Uint8List bytes) : _bytes = bytes;

  final Uint8List _bytes;
  int _offset = 0;

  /// Whether every byte has been read.
  bool get atEnd => _offset >= _bytes.length;

  /// Reads a field tag: its field number and wire type.
  ({int field, int wireType}) readTag() {
    final tag = readVarint();
    return (field: tag ~/ 8, wireType: tag % 8);
  }

  /// Reads a varint, signed as protobuf encodes `int32` and `int64`.
  int readVarint() {
    var lo = 0; // bits 0..31
    var hi = 0; // bits 32..63
    var shift = 0;
    while (true) {
      if (_offset >= _bytes.length || shift >= 64) {
        throw const FormatException(
          'Malformed protobuf: unterminated or truncated varint',
        );
      }
      final byte = _bytes[_offset++];
      final bits = byte & 0x7F;
      if (shift < 32) {
        lo |= (bits << shift) & 0xFFFFFFFF;
        // A group straddling bit 32 spills its top bits into the high half.
        if (shift > 25) hi |= bits >> (32 - shift);
      } else {
        hi |= (bits << (shift - 32)) & 0xFFFFFFFF;
      }
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    lo &= 0xFFFFFFFF;
    hi &= 0xFFFFFFFF;
    // Bit 63 set: the two's complement of a negative int32/int64.
    if ((hi & 0x80000000) != 0) {
      final invLo = (~lo) & 0xFFFFFFFF;
      final invHi = (~hi) & 0xFFFFFFFF;
      final magLo = (invLo + 1) & 0xFFFFFFFF;
      final carry = (invLo + 1) > 0xFFFFFFFF ? 1 : 0;
      return -(((invHi + carry) & 0xFFFFFFFF) * 0x100000000 + magLo);
    }
    return hi * 0x100000000 + lo;
  }

  /// Reads a length-delimited field: a view of its bytes.
  Uint8List readBytes() {
    final length = readVarint();
    if (length < 0 || length > _bytes.length - _offset) {
      throw FormatException(
        'Malformed protobuf: length-delimited field of $length bytes at '
        'offset $_offset exceeds buffer of ${_bytes.length} bytes',
      );
    }
    final field = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return field;
  }

  /// Reads a length-delimited field as UTF-8.
  String readString() => utf8.decode(readBytes());

  /// Skips the value of a field of [wireType] whose tag was just read.
  void skip(int wireType) {
    switch (wireType) {
      case RpcProtoWireType.varint:
        readVarint();
      case RpcProtoWireType.fixed64:
        _advance(8);
      case RpcProtoWireType.lengthDelimited:
        readBytes();
      case RpcProtoWireType.fixed32:
        _advance(4);
      default:
        // 3 and 4 are the deprecated groups.
        throw FormatException('Unsupported protobuf wire type: $wireType');
    }
  }

  void _advance(int count) {
    if (count > _bytes.length - _offset) {
      throw const FormatException('Malformed protobuf: truncated fixed field');
    }
    _offset += count;
  }
}

/// Writes protobuf wire format.
///
/// Writes every field it is asked to: leaving out a default value, as proto3
/// does, is the caller's choice.
final class RpcProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// Writes a field tag.
  void writeTag(int field, int wireType) => writeVarint(field * 8 + wireType);

  /// Writes a varint field.
  void writeVarintField(int field, int value) {
    writeTag(field, RpcProtoWireType.varint);
    writeVarint(value);
  }

  /// Writes a length-delimited field holding [value].
  void writeBytesField(int field, List<int> value) {
    writeTag(field, RpcProtoWireType.lengthDelimited);
    writeVarint(value.length);
    _out.add(value);
  }

  /// Writes a length-delimited field holding [value] as UTF-8.
  void writeStringField(int field, String value) =>
      writeBytesField(field, utf8.encode(value));

  /// Writes [value] as a varint; a negative one as the ten bytes of its
  /// 64-bit two's complement, as protobuf encodes `int32` and `int64`.
  ///
  /// Exact on the web: it never shifts past 32 bits.
  void writeVarint(int value) {
    if (value >= 0) {
      var v = value;
      while (v >= 0x80) {
        _out.addByte((v & 0x7F) | 0x80);
        v = v ~/ 0x80;
      }
      _out.addByte(v & 0x7F);
      return;
    }
    // The unsigned 64-bit two's complement, as 32-bit halves.
    final magnitude = -value;
    final magLo = magnitude & 0xFFFFFFFF;
    final magHi = (magnitude ~/ 0x100000000) & 0xFFFFFFFF;
    final invLo = (~magLo) & 0xFFFFFFFF;
    final invHi = (~magHi) & 0xFFFFFFFF;
    var lo = (invLo + 1) & 0xFFFFFFFF;
    final carry = (invLo + 1) > 0xFFFFFFFF ? 1 : 0;
    var hi = (invHi + carry) & 0xFFFFFFFF;
    // Nine groups of seven bits, each step moving hi's low bits into lo.
    for (var i = 0; i < 9; i++) {
      _out.addByte((lo & 0x7F) | 0x80);
      final carryBits = (hi & 0x7F) * 0x2000000; // hi[0..6] -> lo[25..31]
      lo = ((lo ~/ 0x80) + carryBits) & 0xFFFFFFFF;
      hi = hi ~/ 0x80;
    }
    _out.addByte(lo & 0x7F);
  }

  /// The bytes written so far.
  Uint8List toBytes() => _out.toBytes();
}
