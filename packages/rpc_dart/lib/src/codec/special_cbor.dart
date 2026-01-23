// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart' show IRpcSerializable;

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

  /// Encodes Map<String, dynamic> into CBOR bytes.
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
    return _encode(value, strictMapTypes: false);
  }

  /// Unsafe decoding of CBOR bytes.
  /// Returns dynamic instead of Map<String, dynamic>.
  /// Intended for tests and special cases.
  static dynamic decodeUnsafe(Uint8List bytes) {
    final reader = _CborReader(bytes);
    return reader.readValue();
  }

  /// Encodes any value into CBOR bytes.
  /// When [strictMapTypes] is true, Map inputs must be Map<String, dynamic>.
  static Uint8List _encode(dynamic value, {bool strictMapTypes = true}) {
    // Ensure map inputs use string keys when strict typing is requested.
    if (strictMapTypes && value is Map && value is! Map<String, dynamic>) {
      throw ArgumentError(
        'CborCodec.encode expects Map<String, dynamic>; received an incompatible Map type',
      );
    }

    final builder = BytesBuilder();
    _encodeValue(value, builder);
    return builder.toBytes();
  }

  /// Recursively encodes a value into CBOR.
  static void _encodeValue(dynamic value, BytesBuilder builder) {
    if (value == null) {
      _encodeNull(builder);
    } else if (value is bool) {
      _encodeBool(value, builder);
    } else if (value is int) {
      _encodeInt(value, builder);
    } else if (value is double) {
      _encodeDouble(value, builder);
    } else if (value is String) {
      _encodeString(value, builder);
    } else if (value is Uint8List) {
      _encodeByteString(value, builder);
    } else if (value is List) {
      _encodeList(value, builder);
    } else if (value is Map) {
      _encodeMap(value, builder);
    } else if (value is IRpcSerializable) {
      // For IRpcSerializable use toJson(), which returns Map<String, dynamic>.
      _encodeMap(value.toJson(), builder);
    } else {
      try {
        final json = value.toJson();
        if (json is Map) {
          _encodeMap(json, builder);
        } else if (json is List) {
          _encodeList(json, builder);
        } else {
          _encodeString(json.toString(), builder);
        }
      } catch (e) {
        // Fallback to string for unknown types.
        _encodeString(value.toString(), builder);
      }
    }
  }

  /// Encodes null.
  static void _encodeNull(BytesBuilder builder) {
    builder.addByte(_getMajorTypeByte(_majorTypeSimple, _simpleValueNull));
  }

  /// Encodes a bool.
  static void _encodeBool(bool value, BytesBuilder builder) {
    builder.addByte(
      _getMajorTypeByte(
        _majorTypeSimple,
        value ? _simpleValueTrue : _simpleValueFalse,
      ),
    );
  }

  /// Encodes an int.
  static void _encodeInt(int value, BytesBuilder builder) {
    if (value >= 0) {
      _encodePositiveInt(value, builder);
    } else {
      _encodeNegativeInt(-value - 1, builder);
    }
  }

  /// Encodes a positive integer.
  static void _encodePositiveInt(int value, BytesBuilder builder) {
    if (value <= 23) {
      builder.addByte(_getMajorTypeByte(_majorTypeUnsignedInt, value));
    } else if (value <= 0xFF) {
      builder.addByte(
        _getMajorTypeByte(_majorTypeUnsignedInt, _additionalInfoOneByteFollow),
      );
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFF) {
      builder.addByte(
        _getMajorTypeByte(_majorTypeUnsignedInt, _additionalInfoTwoByteFollow),
      );
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFFFFFF) {
      builder.addByte(
        _getMajorTypeByte(_majorTypeUnsignedInt, _additionalInfoFourByteFollow),
      );
      builder.addByte((value >> 24) & 0xFF);
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else {
      builder.addByte(
        _getMajorTypeByte(
          _majorTypeUnsignedInt,
          _additionalInfoEightByteFollow,
        ),
      );

      // Correct 64-bit integer encoding per RFC 7049.
      builder.addByte((value >> 56) & 0xFF);
      builder.addByte((value >> 48) & 0xFF);
      builder.addByte((value >> 40) & 0xFF);
      builder.addByte((value >> 32) & 0xFF);
      builder.addByte((value >> 24) & 0xFF);
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    }
  }

  /// Encodes a negative integer.
  static void _encodeNegativeInt(int value, BytesBuilder builder) {
    if (value <= 23) {
      builder.addByte(_getMajorTypeByte(_majorTypeNegativeInt, value));
    } else if (value <= 0xFF) {
      builder.addByte(
        _getMajorTypeByte(_majorTypeNegativeInt, _additionalInfoOneByteFollow),
      );
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFF) {
      builder.addByte(
        _getMajorTypeByte(_majorTypeNegativeInt, _additionalInfoTwoByteFollow),
      );
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFFFFFF) {
      builder.addByte(
        _getMajorTypeByte(_majorTypeNegativeInt, _additionalInfoFourByteFollow),
      );
      builder.addByte((value >> 24) & 0xFF);
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else {
      builder.addByte(
        _getMajorTypeByte(
          _majorTypeNegativeInt,
          _additionalInfoEightByteFollow,
        ),
      );

      // Correct 64-bit integer encoding per RFC 7049.
      builder.addByte((value >> 56) & 0xFF);
      builder.addByte((value >> 48) & 0xFF);
      builder.addByte((value >> 40) & 0xFF);
      builder.addByte((value >> 32) & 0xFF);
      builder.addByte((value >> 24) & 0xFF);
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    }
  }

  /// Encodes a double.
  static void _encodeDouble(double value, BytesBuilder builder) {
    // Use IEEE 754 64-bit doubles.
    builder.addByte(
      _getMajorTypeByte(_majorTypeSimple, _additionalInfoEightByteFollow),
    );

    // Convert the double to IEEE 754 bytes.
    final ByteData data = ByteData(8);
    data.setFloat64(0, value, Endian.big); // RFC 7049 uses big-endian.

    // Append bytes.
    for (int i = 0; i < 8; i++) {
      builder.addByte(data.getUint8(i));
    }
  }

  /// Encodes a string.
  static void _encodeString(String value, BytesBuilder builder) {
    // Encode the string as UTF-8 bytes.
    final utf8Bytes = utf8.encode(value);

    // Standard string encoding per RFC 7049.
    _encodeLength(_majorTypeTextString, utf8Bytes.length, builder);
    builder.add(utf8Bytes);
  }

  /// Encodes a binary string.
  static void _encodeByteString(Uint8List bytes, BytesBuilder builder) {
    _encodeLength(_majorTypeByteString, bytes.length, builder);
    builder.add(bytes);
  }

  /// Encodes a list.
  static void _encodeList(List<dynamic> list, BytesBuilder builder) {
    _encodeLength(_majorTypeArray, list.length, builder);
    for (final item in list) {
      _encodeValue(item, builder);
    }
  }

  /// Encodes a map.
  static void _encodeMap(Map<dynamic, dynamic> map, BytesBuilder builder) {
    _encodeLength(_majorTypeMap, map.length, builder);

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
      _encodeString(key.toString(), builder);
      _encodeValue(map[key], builder);
    }
  }

  /// Encodes the length prefix.
  static void _encodeLength(int majorType, int length, BytesBuilder builder) {
    if (length <= 23) {
      builder.addByte(_getMajorTypeByte(majorType, length));
    } else if (length <= 0xFF) {
      builder.addByte(
        _getMajorTypeByte(majorType, _additionalInfoOneByteFollow),
      );
      builder.addByte(length & 0xFF);
    } else if (length <= 0xFFFF) {
      builder.addByte(
        _getMajorTypeByte(majorType, _additionalInfoTwoByteFollow),
      );
      builder.addByte((length >> 8) & 0xFF);
      builder.addByte(length & 0xFF);
    } else if (length <= 0xFFFFFFFF) {
      builder.addByte(
        _getMajorTypeByte(majorType, _additionalInfoFourByteFollow),
      );
      builder.addByte((length >> 24) & 0xFF);
      builder.addByte((length >> 16) & 0xFF);
      builder.addByte((length >> 8) & 0xFF);
      builder.addByte(length & 0xFF);
    } else {
      builder.addByte(
        _getMajorTypeByte(majorType, _additionalInfoEightByteFollow),
      );
      builder.addByte((length >> 56) & 0xFF);
      builder.addByte((length >> 48) & 0xFF);
      builder.addByte((length >> 40) & 0xFF);
      builder.addByte((length >> 32) & 0xFF);
      builder.addByte((length >> 24) & 0xFF);
      builder.addByte((length >> 16) & 0xFF);
      builder.addByte((length >> 8) & 0xFF);
      builder.addByte(length & 0xFF);
    }
  }

  /// Builds the header byte.
  static int _getMajorTypeByte(int majorType, int additionalInfo) {
    return (majorType << 5) | (additionalInfo & 0x1F);
  }

  /// Converts Map<dynamic, dynamic> to Map<String, dynamic>.
  static Map<String, dynamic> _ensureStringKeys(Map<dynamic, dynamic> map) {
    return map.map((key, value) {
      // Recursively process nested maps.
      if (value is Map) {
        value = _ensureStringKeys(value);
      } else if (value is List) {
        value = _processListItems(value);
      }
      return MapEntry(key.toString(), value);
    });
  }

  /// Processes list items, converting nested maps.
  static List<dynamic> _processListItems(List<dynamic> list) {
    return list.map((item) {
      if (item is Map) {
        return _ensureStringKeys(item);
      } else if (item is List) {
        return _processListItems(item);
      }
      return item;
    }).toList();
  }
}

/// Helper reader for CBOR data.
class _CborReader {
  final Uint8List _bytes;
  int _offset = 0;

  _CborReader(this._bytes);

  /// Reads the next value from the byte stream.
  dynamic readValue() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }

    final byte = _bytes[_offset++];
    final majorType = byte >> 5;
    final additionalInfo = byte & 0x1F;

    switch (majorType) {
      case CborCodec._majorTypeUnsignedInt:
        return _readUnsignedInt(additionalInfo);
      case CborCodec._majorTypeNegativeInt:
        return -_readUnsignedInt(additionalInfo) - 1;
      case CborCodec._majorTypeByteString:
        return _readByteString(additionalInfo);
      case CborCodec._majorTypeTextString:
        return _readTextString(additionalInfo);
      case CborCodec._majorTypeArray:
        return _readArray(additionalInfo);
      case CborCodec._majorTypeMap:
        return _readMap(additionalInfo);
      case CborCodec._majorTypeTag:
        // Skip the tag and read the value.
        _readUnsignedInt(additionalInfo);
        return readValue();
      case CborCodec._majorTypeSimple:
        return _readSimpleValue(additionalInfo);
      default:
        throw FormatException('Unknown CBOR major type: $majorType');
    }
  }

  /// Reads an unsigned integer.
  int _readUnsignedInt(int additionalInfo) {
    if (additionalInfo < 24) {
      return additionalInfo;
    }

    switch (additionalInfo) {
      case CborCodec._additionalInfoOneByteFollow:
        return _readByte();
      case CborCodec._additionalInfoTwoByteFollow:
        return (_readByte() << 8) | _readByte();
      case CborCodec._additionalInfoFourByteFollow:
        return (_readByte() << 24) |
            (_readByte() << 16) |
            (_readByte() << 8) |
            _readByte();
      case CborCodec._additionalInfoEightByteFollow:
        // Read 8 bytes as a big-endian integer.
        int result = 0;
        for (int i = 0; i < 8; i++) {
          result = (result << 8) | _readByte();
        }
        return result;
      case CborCodec._additionalInfoIndefiniteLength:
        throw FormatException('Indefinite length not implemented');
      default:
        throw FormatException('Unknown additional info: $additionalInfo');
    }
  }

  /// Reads a byte string.
  Uint8List _readByteString(int additionalInfo) {
    final length = _readLength(additionalInfo);

    if (_offset + length > _bytes.length) {
      throw FormatException('Byte string length exceeds available data');
    }

    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  /// Reads a text string.
  String _readTextString(int additionalInfo) {
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

  /// Reads an array.
  List<dynamic> _readArray(int additionalInfo) {
    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      final result = <dynamic>[];

      // Consume elements until a break marker appears.
      while (true) {
        if (_offset >= _bytes.length) {
          throw FormatException(
            'Unexpected end of CBOR data inside indefinite-length array',
          );
        }

        // Check for the break marker.
        if (_bytes[_offset] ==
            CborCodec._getMajorTypeByte(
              CborCodec._majorTypeSimple,
              CborCodec._simpleValueBreak,
            )) {
          _offset++; // Skip the break marker.
          break;
        }

        // Read next element.
        result.add(readValue());
      }

      return result;
    }

    final length = _readLength(additionalInfo);
    final result = <dynamic>[];

    for (int i = 0; i < length; i++) {
      result.add(readValue());
    }

    return result;
  }

  /// Reads a map.
  Map<String, dynamic> _readMap(int additionalInfo) {
    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      final result = <String, dynamic>{};

      // Read key/value pairs until a break marker is found.
      while (true) {
        if (_offset >= _bytes.length) {
          throw FormatException(
            'Unexpected end of CBOR data inside indefinite-length map',
          );
        }

        // Check for the break marker.
        if (_bytes[_offset] ==
            CborCodec._getMajorTypeByte(
              CborCodec._majorTypeSimple,
              CborCodec._simpleValueBreak,
            )) {
          _offset++; // Skip the break marker.
          break;
        }

        // Read a key/value pair.
        final key = readValue();
        final value = readValue();
        result[key.toString()] = value;
      }

      return result;
    }

    final length = _readLength(additionalInfo);
    final result = <String, dynamic>{};

    for (int i = 0; i < length; i++) {
      final key = readValue();
      final value = readValue();
      result[key.toString()] = value;
    }

    return result;
  }

  /// Reads a simple value.
  dynamic _readSimpleValue(int additionalInfo) {
    switch (additionalInfo) {
      case CborCodec._simpleValueFalse:
        return false;
      case CborCodec._simpleValueTrue:
        return true;
      case CborCodec._simpleValueNull:
        return null;
      case CborCodec._simpleValueUndefined:
        // Dart treats undefined as null.
        return null;
      case CborCodec._simpleValueBreak:
        throw FormatException(
          'Unexpected break value outside indefinite-length item',
        );
      case CborCodec._additionalInfoEightByteFollow:
        // IEEE 754 Double.
        final byteData = ByteData(8);
        for (int i = 0; i < 8; i++) {
          byteData.setUint8(i, _readByte());
        }
        return byteData.getFloat64(
          0,
          Endian.big,
        ); // Use big-endian per RFC 7049.
      default:
        if (additionalInfo >= 0 && additionalInfo <= 19) {
          // Simple values 0-19.
          return additionalInfo;
        }
        if (additionalInfo == CborCodec._additionalInfoOneByteFollow) {
          // Extended simple value (1 byte).
          return _readByte();
        }
        throw FormatException('Unknown simple value: $additionalInfo');
    }
  }

  /// Reads a length field.
  int _readLength(int additionalInfo) {
    if (additionalInfo < 24) {
      return additionalInfo;
    }

    switch (additionalInfo) {
      case CborCodec._additionalInfoOneByteFollow:
      case CborCodec._additionalInfoTwoByteFollow:
      case CborCodec._additionalInfoFourByteFollow:
      case CborCodec._additionalInfoEightByteFollow:
        return _readUnsignedInt(additionalInfo);
      case CborCodec._additionalInfoIndefiniteLength:
        throw FormatException('Indefinite length not implemented');
      default:
        throw FormatException('Unknown additional info: $additionalInfo');
    }
  }

  /// Reads a single byte.
  int _readByte() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }
    return _bytes[_offset++];
  }
}

/// OPTIMIZED: Fast CBOR reader for Map<String, dynamic>.
/// Avoids redundant checks and type conversions.
class _FastCborReader {
  final Uint8List _bytes;
  int _offset = 0;

  _FastCborReader(this._bytes);

  /// Reads Map<String, dynamic> directly without extra conversions.
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
    final length = _readLength(additionalInfo);
    final result = <String, dynamic>{};

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
        int result = 0;
        for (int i = 0; i < 8; i++) {
          result = (result << 8) | _readByteFast();
        }
        return result;
      default:
        throw FormatException('Unknown additional info: $additionalInfo');
    }
  }

  /// Fast byte string read.
  Uint8List _readByteStringFast(int additionalInfo) {
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
    final length = _readLength(additionalInfo);
    final result = <dynamic>[];

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
        throw FormatException('Unknown simple value: $additionalInfo');
    }
  }

  /// Fast length read.
  int _readLength(int additionalInfo) {
    if (additionalInfo < 24) {
      return additionalInfo;
    }
    return _readUnsignedIntFast(additionalInfo);
  }

  /// Inline fast single-byte read.
  int _readByteFast() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }
    return _bytes[_offset++];
  }
}

/// OPTIMIZED: Fast CBOR writer for Map<String, dynamic>.
/// Avoids redundant checks and type conversions.
class _FastCborWriter {
  final BytesBuilder _builder = BytesBuilder();

  /// Returns encoded bytes.
  Uint8List toBytes() => _builder.toBytes();

  /// Encodes Map<String, dynamic> into CBOR bytes.
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
    } else if (value is List) {
      _writeList(value);
    } else if (value is Map) {
      _writeMap(value);
    } else if (value is IRpcSerializable) {
      // For IRpcSerializable use toJson(), which returns Map<String, dynamic>.
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

      // Correct 64-bit integer encoding per RFC 7049.
      _builder.addByte((value >> 56) & 0xFF);
      _builder.addByte((value >> 48) & 0xFF);
      _builder.addByte((value >> 40) & 0xFF);
      _builder.addByte((value >> 32) & 0xFF);
      _builder.addByte((value >> 24) & 0xFF);
      _builder.addByte((value >> 16) & 0xFF);
      _builder.addByte((value >> 8) & 0xFF);
      _builder.addByte(value & 0xFF);
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

      // Correct 64-bit integer encoding per RFC 7049.
      _builder.addByte((value >> 56) & 0xFF);
      _builder.addByte((value >> 48) & 0xFF);
      _builder.addByte((value >> 40) & 0xFF);
      _builder.addByte((value >> 32) & 0xFF);
      _builder.addByte((value >> 24) & 0xFF);
      _builder.addByte((value >> 16) & 0xFF);
      _builder.addByte((value >> 8) & 0xFF);
      _builder.addByte(value & 0xFF);
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
      _builder.addByte((length >> 56) & 0xFF);
      _builder.addByte((length >> 48) & 0xFF);
      _builder.addByte((length >> 40) & 0xFF);
      _builder.addByte((length >> 32) & 0xFF);
      _builder.addByte((length >> 24) & 0xFF);
      _builder.addByte((length >> 16) & 0xFF);
      _builder.addByte((length >> 8) & 0xFF);
      _builder.addByte(length & 0xFF);
    }
  }

  /// Builds the header byte.
  int _getMajorTypeByte(int majorType, int additionalInfo) {
    return (majorType << 5) | (additionalInfo & 0x1F);
  }
}
