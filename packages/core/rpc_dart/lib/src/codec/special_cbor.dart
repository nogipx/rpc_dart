// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart' show IRpcSerializable;

/// Writes a 64-bit unsigned integer as 8 big-endian bytes.
///
/// Uses two 32-bit writes instead of [ByteData.setUint64] which is
/// unsupported in dart2js (JavaScript has no 64-bit integer type).
void _writeUint64BigEndian(BytesBuilder builder, int value) {
  // Defensive backstop: a non-finite value here would make `~/` throw on
  // dart2js with an opaque message. Callers route non-finite doubles to the
  // double encoder, so reaching this is a programming error -- fail clearly.
  final asNum = value as num;
  if (asNum.isNaN || asNum.isInfinite) {
    throw FormatException(
      'Cannot encode non-finite value $value as a 64-bit integer',
    );
  }
  final hi = (value ~/ 0x100000000) & 0xFFFFFFFF;
  final lo = value & 0xFFFFFFFF;
  builder.addByte((hi >> 24) & 0xFF);
  builder.addByte((hi >> 16) & 0xFF);
  builder.addByte((hi >> 8) & 0xFF);
  builder.addByte(hi & 0xFF);
  builder.addByte((lo >> 24) & 0xFF);
  builder.addByte((lo >> 16) & 0xFF);
  builder.addByte((lo >> 8) & 0xFF);
  builder.addByte(lo & 0xFF);
}

/// Decodes an IEEE 754 half-precision (16-bit) float from two big-endian bytes.
///
/// CBOR encoders may emit half floats (major type 7, additional info 25).
/// Neither writer in this file produces them, but a conforming decoder must
/// accept them for interoperability.
double _decodeHalfFloat(int hi, int lo) {
  final half = (hi << 8) | lo;
  final exp = (half >> 10) & 0x1F;
  final mant = half & 0x3FF;
  final sign = (half & 0x8000) != 0 ? -1.0 : 1.0;

  double value;
  if (exp == 0) {
    // Subnormal: value = mant * 2^-24.
    value = mant * 5.960464477539063e-8;
  } else if (exp == 0x1F) {
    // Infinity or NaN.
    value = mant == 0 ? double.infinity : double.nan;
  } else {
    // Normal: value = (1 + mant/1024) * 2^(exp-15).
    value = (1.0 + mant / 1024.0) * _pow2(exp - 15);
  }
  return sign * value;
}

/// Computes 2^n for integer n without bit-shifts (dart2js-safe for any range).
double _pow2(int n) {
  double result = 1.0;
  final base = n < 0 ? 0.5 : 2.0;
  final count = n < 0 ? -n : n;
  for (int i = 0; i < count; i++) {
    result *= base;
  }
  return result;
}

/// CBOR (Concise Binary Object Representation) implementation for RPC.
/// Format reference: RFC 7049 https://tools.ietf.org/html/rfc7049
abstract interface class CborCodec {
  /// Major type constants.
  static const int _majorTypeUnsignedInt = 0;
  static const int _majorTypeNegativeInt = 1;
  static const int _majorTypeByteString = 2;
  static const int _majorTypeTextString = 3;
  static const int _majorTypeArray = 4;
  static const int _majorTypeMap = 5;
  static const int _majorTypeTag = 6;
  static const int _majorTypeSimple = 7;

  /// Additional info constants.
  static const int _additionalInfoIndefiniteLength = 31;
  static const int _additionalInfoOneByteFollow = 24;
  static const int _additionalInfoTwoByteFollow = 25;
  static const int _additionalInfoFourByteFollow = 26;
  static const int _additionalInfoEightByteFollow = 27;

  /// Special values.
  static const int _simpleValueFalse = 20;
  static const int _simpleValueTrue = 21;
  static const int _simpleValueNull = 22;
  static const int _simpleValueUndefined = 23;
  static const int _simpleValueBreak = 31;

  /// 2^64, the smallest magnitude a CBOR major-type-0/1 integer cannot hold.
  /// On dart2js a finite integer-valued double at or beyond this (e.g. 1e300)
  /// reports `is int`, so the integer encoders fall back to a double for it.
  static const double _cborIntDoubleThreshold = 18446744073709551616.0;

  /// Encodes Map(String, dynamic) into CBOR bytes.
  static Uint8List encode(Map<String, dynamic> value) {
    final writer = _FastCborWriter();
    writer.writeMap(value);
    return writer.toBytes();
  }

  /// Decodes CBOR bytes into Dart objects.
  static Map<String, dynamic> decode(Uint8List bytes) {
    final reader = _FastCborReader(bytes);
    return reader.readMap();
  }

  /// Unsafe encoding of any value into CBOR bytes.
  /// Does not validate map key types; accepts any Map variant.
  /// Intended for tests and special cases.
  static Uint8List encodeUnsafe(dynamic value) {
    final writer = _FastCborWriter();
    writer.writeValue(value);
    return writer.toBytes();
  }

  /// Unsafe decoding of CBOR bytes.
  /// Returns dynamic instead of Map(String, dynamic).
  /// Intended for tests and special cases.
  static dynamic decodeUnsafe(Uint8List bytes) {
    final reader = _FastCborReader(bytes);
    return reader.readValue();
  }

  /// Builds the header byte.
  static int _getMajorTypeByte(int majorType, int additionalInfo) {
    return (majorType << 5) | (additionalInfo & 0x1F);
  }
}

/// OPTIMIZED: Fast CBOR reader.
/// Avoids redundant checks and type conversions.
///
/// This is the single decoder. [readMap] backs the production decode() path
/// (top-level must be a map); [readValue] backs decodeUnsafe() (any top-level
/// value to dynamic). Decoding correctness is guarded by
/// test/serializers/cbor_parity_test.dart.
class _FastCborReader {
  final Uint8List _bytes;
  int _offset = 0;

  _FastCborReader(this._bytes);

  /// Reads any top-level value as dynamic (backs decodeUnsafe).
  ///
  /// Returns the same container types as [readMap] for nested data:
  /// `Map<String, dynamic>` for maps, `List<dynamic>` for arrays, [Uint8List]
  /// for byte strings, plus String/int/double/bool/null for scalars.
  dynamic readValue() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }
    return _readValueFast();
  }

  /// Reads Map(String, dynamic) directly without extra conversions.
  Map<String, dynamic> readMap() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }

    final byte = _bytes[_offset++];
    final majorType = byte >> 5;
    final additionalInfo = byte & 0x1F;

    if (majorType != CborCodec._majorTypeMap) {
      throw FormatException('Expected map, got major type: $majorType');
    }

    return _readMapFast(additionalInfo);
  }

  /// Fast map reading with minimal overhead.
  Map<String, dynamic> _readMapFast(int additionalInfo) {
    final result = <String, dynamic>{};

    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      // Indefinite-length map: read key/value pairs until a break marker.
      while (!_consumeBreakMarker('indefinite-length map')) {
        final key = _readStringFast();
        final value = _readValueFast();
        result[key] = value;
      }
      return result;
    }

    final length = _readLength(additionalInfo);

    for (int i = 0; i < length; i++) {
      // Keys are always strings.
      final key = _readStringFast();
      // Then read the value.
      final value = _readValueFast();
      result[key] = value;
    }

    return result;
  }

  /// Fast string read without caching.
  String _readStringFast() {
    final byte = _bytes[_offset++];
    final majorType = byte >> 5;
    final additionalInfo = byte & 0x1F;

    if (majorType != CborCodec._majorTypeTextString) {
      throw FormatException('Expected text string, got major type: $majorType');
    }

    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      // Indefinite-length text string: definite-length chunks until a break.
      final buffer = StringBuffer();
      while (!_consumeBreakMarker('indefinite-length text string')) {
        final chunkByte = _bytes[_offset];
        if ((chunkByte >> 5) != CborCodec._majorTypeTextString) {
          throw FormatException(
            'Indefinite-length text string contains a non-text-string chunk',
          );
        }
        buffer.write(_readStringFast());
      }
      return buffer.toString();
    }

    final length = _readLength(additionalInfo);

    if (_offset + length > _bytes.length) {
      throw FormatException('Text string length exceeds available data');
    }

    final utf8Bytes = _bytes.sublist(_offset, _offset + length);
    _offset += length;

    try {
      return utf8.decode(utf8Bytes);
    } catch (e) {
      throw FormatException('Invalid UTF-8 sequence in text string');
    }
  }

  /// Fast value read optimized for hot paths.
  dynamic _readValueFast() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }

    final byte = _bytes[_offset++];
    final majorType = byte >> 5;
    final additionalInfo = byte & 0x1F;

    // Optimized for the most common types.
    switch (majorType) {
      case CborCodec._majorTypeUnsignedInt:
        return _readUnsignedIntFast(additionalInfo);
      case CborCodec._majorTypeNegativeInt:
        return -_readUnsignedIntFast(additionalInfo) - 1;
      case CborCodec._majorTypeTextString:
        // Step back one byte and read as string.
        _offset--;
        return _readStringFast();
      case CborCodec._majorTypeByteString:
        return _readByteStringFast(additionalInfo);
      case CborCodec._majorTypeArray:
        return _readArrayFast(additionalInfo);
      case CborCodec._majorTypeMap:
        return _readMapFast(additionalInfo);
      case CborCodec._majorTypeTag:
        // Skip the tag and read the tagged value (mirrors the slow reader).
        _readUnsignedIntFast(additionalInfo);
        return _readValueFast();
      case CborCodec._majorTypeSimple:
        return _readSimpleValueFast(additionalInfo);
      default:
        throw FormatException('Unknown CBOR major type: $majorType');
    }
  }

  /// Fast unsigned int read.
  int _readUnsignedIntFast(int additionalInfo) {
    if (additionalInfo < 24) {
      return additionalInfo;
    }

    switch (additionalInfo) {
      case CborCodec._additionalInfoOneByteFollow:
        return _readByteFast();
      case CborCodec._additionalInfoTwoByteFollow:
        return (_readByteFast() << 8) | _readByteFast();
      case CborCodec._additionalInfoFourByteFollow:
        return (_readByteFast() << 24) |
            (_readByteFast() << 16) |
            (_readByteFast() << 8) |
            _readByteFast();
      case CborCodec._additionalInfoEightByteFollow:
        // Combine high/low 32-bit halves without a >32-bit shift (dart2js-safe).
        final hi = (_readByteFast() * 0x1000000) +
            (_readByteFast() << 16) +
            (_readByteFast() << 8) +
            _readByteFast();
        final lo = (_readByteFast() * 0x1000000) +
            (_readByteFast() << 16) +
            (_readByteFast() << 8) +
            _readByteFast();
        return hi * 0x100000000 + lo;
      case CborCodec._additionalInfoIndefiniteLength:
        // Mirrors the slow reader's message for malformed indefinite ints/tags.
        throw FormatException('Indefinite length not implemented');
      default:
        throw FormatException('Unknown additional info: $additionalInfo');
    }
  }

  /// Fast byte string read.
  Uint8List _readByteStringFast(int additionalInfo) {
    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      // Indefinite-length byte string: definite-length chunks until a break.
      final builder = BytesBuilder();
      while (!_consumeBreakMarker('indefinite-length byte string')) {
        final chunkByte = _readByteFast();
        if ((chunkByte >> 5) != CborCodec._majorTypeByteString) {
          throw FormatException(
            'Indefinite-length byte string contains a non-byte-string chunk',
          );
        }
        builder.add(_readByteStringFast(chunkByte & 0x1F));
      }
      return builder.toBytes();
    }

    final length = _readLength(additionalInfo);

    if (_offset + length > _bytes.length) {
      throw FormatException('Byte string length exceeds available data');
    }

    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  /// Fast array read.
  List<dynamic> _readArrayFast(int additionalInfo) {
    final result = <dynamic>[];

    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      // Indefinite-length array: elements until a break marker.
      while (!_consumeBreakMarker('indefinite-length array')) {
        result.add(_readValueFast());
      }
      return result;
    }

    final length = _readLength(additionalInfo);

    for (int i = 0; i < length; i++) {
      result.add(_readValueFast());
    }

    return result;
  }

  /// Fast read for simple values.
  dynamic _readSimpleValueFast(int additionalInfo) {
    switch (additionalInfo) {
      case CborCodec._simpleValueFalse:
        return false;
      case CborCodec._simpleValueTrue:
        return true;
      case CborCodec._simpleValueNull:
        return null;
      case CborCodec._simpleValueUndefined:
        // Dart treats undefined as null (mirrors the slow reader).
        return null;
      case CborCodec._simpleValueBreak:
        // Same dedicated message as the slow reader for parity.
        throw FormatException(
          'Unexpected break value outside indefinite-length item',
        );
      case CborCodec._additionalInfoTwoByteFollow:
        // IEEE 754 half-precision float (16-bit).
        return _decodeHalfFloat(_readByteFast(), _readByteFast());
      case CborCodec._additionalInfoFourByteFollow:
        // IEEE 754 single-precision float (32-bit).
        final byteData = ByteData(4);
        for (int i = 0; i < 4; i++) {
          byteData.setUint8(i, _readByteFast());
        }
        return byteData.getFloat32(0, Endian.big);
      case CborCodec._additionalInfoEightByteFollow:
        // Inline IEEE 754 double for speed.
        final byteData = ByteData(8);
        for (int i = 0; i < 8; i++) {
          byteData.setUint8(i, _readByteFast());
        }
        return byteData.getFloat64(0, Endian.big);
      default:
        if (additionalInfo >= 0 && additionalInfo <= 19) {
          return additionalInfo;
        }
        if (additionalInfo == CborCodec._additionalInfoOneByteFollow) {
          // Extended simple value (1 byte), mirrors the slow reader.
          return _readByteFast();
        }
        throw FormatException('Unknown simple value: $additionalInfo');
    }
  }

  /// Fast length read.
  int _readLength(int additionalInfo) {
    if (additionalInfo < 24) {
      return additionalInfo;
    }
    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      // Indefinite length reaching this point means a non-container (e.g. int)
      // used additional info 31, which is not a valid definite length.
      throw FormatException('Indefinite length not implemented');
    }
    return _readUnsignedIntFast(additionalInfo);
  }

  /// Returns true and consumes a break marker if one is at the current offset.
  /// Throws if the stream ends before a break is found.
  bool _consumeBreakMarker(String context) {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data inside $context');
    }
    if (_bytes[_offset] ==
        CborCodec._getMajorTypeByte(
          CborCodec._majorTypeSimple,
          CborCodec._simpleValueBreak,
        )) {
      _offset++;
      return true;
    }
    return false;
  }

  /// Inline fast single-byte read.
  int _readByteFast() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }
    return _bytes[_offset++];
  }
}

/// OPTIMIZED: Fast CBOR writer for Map(String, dynamic).
/// Avoids redundant checks and type conversions.
class _FastCborWriter {
  final BytesBuilder _builder = BytesBuilder();

  /// Returns encoded bytes.
  Uint8List toBytes() => _builder.toBytes();

  /// Encodes Map(String, dynamic) into CBOR bytes.
  void writeMap(Map<String, dynamic> value) {
    _writeLength(CborCodec._majorTypeMap, value.length);

    // RFC 7049 recommends sorting keys for deterministic encoding.
    final keys = value.keys.toList()
      ..sort((a, b) {
        // Convert to strings first, then compare.
        final aString = a.toString();
        final bString = b.toString();
        // Byte-by-byte comparison.
        final aBytes = utf8.encode(aString);
        final bBytes = utf8.encode(bString);
        for (int i = 0; i < aBytes.length && i < bBytes.length; i++) {
          if (aBytes[i] != bBytes[i]) {
            return aBytes[i] - bBytes[i];
          }
        }
        return aBytes.length - bBytes.length;
      });

    for (final key in keys) {
      // Encode keys as strings for compatibility.
      _writeString(key.toString());
      _writeValue(value[key]);
    }
  }

  /// Encodes any top-level value into CBOR bytes (backs encodeUnsafe).
  /// Accepts any Map variant via lax key coercion (key.toString()).
  void writeValue(dynamic value) => _writeValue(value);

  /// Encodes a value into CBOR bytes.
  void _writeValue(dynamic value) {
    if (value == null) {
      _writeNull();
    } else if (value is bool) {
      _writeBool(value);
    } else if (value is int) {
      _writeInt(value);
    } else if (value is double) {
      _writeDouble(value);
    } else if (value is String) {
      _writeString(value);
    } else if (value is Uint8List) {
      _writeByteString(value);
    } else if (value is TypedData && value is List<int>) {
      // Catch typed int arrays (e.g. Int8List, Uint8ClampedList) that dart2js
      // may not recognize as Uint8List due to JS interop boundaries.
      _writeByteString(Uint8List.fromList(value as List<int>));
    } else if (value is List) {
      _writeList(value);
    } else if (value is Map) {
      _writeMap(value);
    } else if (value is IRpcSerializable) {
      // For IRpcSerializable use toJson(), which returns Map(String, dynamic).
      _writeMap(value.toJson());
    } else {
      try {
        final json = value.toJson();
        if (json is Map) {
          _writeMap(json);
        } else if (json is List) {
          _writeList(json);
        } else {
          _writeString(json.toString());
        }
      } catch (e) {
        // Fallback to string for unknown types.
        _writeString(value.toString());
      }
    }
  }

  /// Encodes null.
  void _writeNull() {
    _builder.addByte(
      _getMajorTypeByte(CborCodec._majorTypeSimple, CborCodec._simpleValueNull),
    );
  }

  /// Encodes a bool.
  void _writeBool(bool value) {
    _builder.addByte(
      _getMajorTypeByte(
        CborCodec._majorTypeSimple,
        value ? CborCodec._simpleValueTrue : CborCodec._simpleValueFalse,
      ),
    );
  }

  /// Encodes an int.
  void _writeInt(int value) {
    // On dart2js there is a single number type, so a non-finite double
    // (Infinity/NaN) can reach this path via `value is int`. Such values have
    // no integer representation; encode them as IEEE 754 doubles instead.
    final asNum = value as num;
    // On dart2js a finite integer-valued double whose magnitude exceeds the
    // CBOR 64-bit integer range (e.g. 1e300) also satisfies `value is int`.
    // It cannot be encoded as a uint64/negative-int; encode it as a double.
    if (asNum.isNaN ||
        asNum.isInfinite ||
        asNum >= CborCodec._cborIntDoubleThreshold ||
        asNum < -CborCodec._cborIntDoubleThreshold) {
      _writeDouble(asNum.toDouble());
      return;
    }
    if (value >= 0) {
      _writePositiveInt(value);
    } else {
      _writeNegativeInt(-value - 1);
    }
  }

  /// Encodes a positive integer.
  void _writePositiveInt(int value) {
    if (value <= 23) {
      _builder.addByte(
        _getMajorTypeByte(CborCodec._majorTypeUnsignedInt, value),
      );
    } else if (value <= 0xFF) {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeUnsignedInt,
          CborCodec._additionalInfoOneByteFollow,
        ),
      );
      _builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFF) {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeUnsignedInt,
          CborCodec._additionalInfoTwoByteFollow,
        ),
      );
      _builder.addByte((value >> 8) & 0xFF);
      _builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFFFFFF) {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeUnsignedInt,
          CborCodec._additionalInfoFourByteFollow,
        ),
      );
      _builder.addByte((value >> 24) & 0xFF);
      _builder.addByte((value >> 16) & 0xFF);
      _builder.addByte((value >> 8) & 0xFF);
      _builder.addByte(value & 0xFF);
    } else {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeUnsignedInt,
          CborCodec._additionalInfoEightByteFollow,
        ),
      );

      _writeUint64BigEndian(_builder, value);
    }
  }

  /// Encodes a negative integer.
  void _writeNegativeInt(int value) {
    if (value <= 23) {
      _builder.addByte(
        _getMajorTypeByte(CborCodec._majorTypeNegativeInt, value),
      );
    } else if (value <= 0xFF) {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeNegativeInt,
          CborCodec._additionalInfoOneByteFollow,
        ),
      );
      _builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFF) {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeNegativeInt,
          CborCodec._additionalInfoTwoByteFollow,
        ),
      );
      _builder.addByte((value >> 8) & 0xFF);
      _builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFFFFFF) {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeNegativeInt,
          CborCodec._additionalInfoFourByteFollow,
        ),
      );
      _builder.addByte((value >> 24) & 0xFF);
      _builder.addByte((value >> 16) & 0xFF);
      _builder.addByte((value >> 8) & 0xFF);
      _builder.addByte(value & 0xFF);
    } else {
      _builder.addByte(
        _getMajorTypeByte(
          CborCodec._majorTypeNegativeInt,
          CborCodec._additionalInfoEightByteFollow,
        ),
      );

      _writeUint64BigEndian(_builder, value);
    }
  }

  /// Encodes a double.
  void _writeDouble(double value) {
    // Use IEEE 754 64-bit (double).
    _builder.addByte(
      _getMajorTypeByte(
        CborCodec._majorTypeSimple,
        CborCodec._additionalInfoEightByteFollow,
      ),
    );

    // Convert double to bytes in IEEE 754 format.
    final ByteData data = ByteData(8);
    data.setFloat64(0, value, Endian.big); // RFC 7049 uses big-endian.

    // Append bytes.
    for (int i = 0; i < 8; i++) {
      _builder.addByte(data.getUint8(i));
    }
  }

  /// Encodes a string.
  void _writeString(String value) {
    // Encode the string as UTF-8 bytes.
    final utf8Bytes = utf8.encode(value);

    // Standard string encoding per RFC 7049.
    _writeLength(CborCodec._majorTypeTextString, utf8Bytes.length);
    _builder.add(utf8Bytes);
  }

  /// Encodes a binary string.
  void _writeByteString(Uint8List bytes) {
    _writeLength(CborCodec._majorTypeByteString, bytes.length);
    _builder.add(bytes);
  }

  /// Encodes a list.
  void _writeList(List<dynamic> list) {
    _writeLength(CborCodec._majorTypeArray, list.length);
    for (final item in list) {
      _writeValue(item);
    }
  }

  /// Encodes a map.
  void _writeMap(Map<dynamic, dynamic> map) {
    _writeLength(CborCodec._majorTypeMap, map.length);

    // RFC 7049 recommends sorting keys for deterministic encoding.
    final keys = map.keys.toList()
      ..sort((a, b) {
        // Convert to strings first, then compare.
        final aString = a.toString();
        final bString = b.toString();
        // Byte-by-byte comparison.
        final aBytes = utf8.encode(aString);
        final bBytes = utf8.encode(bString);
        for (int i = 0; i < aBytes.length && i < bBytes.length; i++) {
          if (aBytes[i] != bBytes[i]) {
            return aBytes[i] - bBytes[i];
          }
        }
        return aBytes.length - bBytes.length;
      });

    for (final key in keys) {
      // Encode keys as strings for compatibility.
      _writeString(key.toString());
      _writeValue(map[key]);
    }
  }

  /// Encodes the length prefix.
  void _writeLength(int majorType, int length) {
    if (length <= 23) {
      _builder.addByte(_getMajorTypeByte(majorType, length));
    } else if (length <= 0xFF) {
      _builder.addByte(
        _getMajorTypeByte(majorType, CborCodec._additionalInfoOneByteFollow),
      );
      _builder.addByte(length & 0xFF);
    } else if (length <= 0xFFFF) {
      _builder.addByte(
        _getMajorTypeByte(majorType, CborCodec._additionalInfoTwoByteFollow),
      );
      _builder.addByte((length >> 8) & 0xFF);
      _builder.addByte(length & 0xFF);
    } else if (length <= 0xFFFFFFFF) {
      _builder.addByte(
        _getMajorTypeByte(majorType, CborCodec._additionalInfoFourByteFollow),
      );
      _builder.addByte((length >> 24) & 0xFF);
      _builder.addByte((length >> 16) & 0xFF);
      _builder.addByte((length >> 8) & 0xFF);
      _builder.addByte(length & 0xFF);
    } else {
      _builder.addByte(
        _getMajorTypeByte(majorType, CborCodec._additionalInfoEightByteFollow),
      );
      _writeUint64BigEndian(_builder, length);
    }
  }

  /// Builds the header byte.
  int _getMajorTypeByte(int majorType, int additionalInfo) {
    return (majorType << 5) | (additionalInfo & 0x1F);
  }
}
