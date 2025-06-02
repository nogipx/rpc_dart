// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// part of '../../contracts/_index.dart';

import 'dart:convert';

import '../../rpc_dart.dart';

/// Реализация CBOR (Concise Binary Object Representation) для RPC
/// Формат описан в RFC 7049: https://tools.ietf.org/html/rfc7049
abstract interface class CborCodec {
  /// Константы для мажорных типов
  static const int _majorTypeUnsignedInt = 0;
  static const int _majorTypeNegativeInt = 1;
  static const int _majorTypeByteString = 2;
  static const int _majorTypeTextString = 3;
  static const int _majorTypeArray = 4;
  static const int _majorTypeMap = 5;
  static const int _majorTypeTag = 6;
  static const int _majorTypeSimple = 7;

  /// Константы для дополнительной информации
  static const int _additionalInfoIndefiniteLength = 31;
  static const int _additionalInfoOneByteFollow = 24;
  static const int _additionalInfoTwoByteFollow = 25;
  static const int _additionalInfoFourByteFollow = 26;
  static const int _additionalInfoEightByteFollow = 27;

  /// Специальные значения
  static const int _simpleValueFalse = 20;
  static const int _simpleValueTrue = 21;
  static const int _simpleValueNull = 22;
  static const int _simpleValueUndefined = 23;
  static const int _simpleValueBreak = 31;

  /// Кодирует Map(String, dynamic) в байты CBOR
  static Uint8List encode(Map<String, dynamic> value) {
    return _encode(value, strictMapTypes: true);
  }

  /// Декодирует CBOR байты в Dart объекты
  static Map<String, dynamic> decode(Uint8List bytes) {
    return _decode(bytes, strictMapTypes: true) as Map<String, dynamic>;
  }

  /// Кодирует любое значение в байты CBOR
  static Uint8List encodeUnsafe(dynamic value) {
    return _encode(value, strictMapTypes: false);
  }

  /// Декодирует CBOR байты в Dart объекты
  static dynamic decodeUnsafe(Uint8List bytes) {
    return _decode(bytes, strictMapTypes: false);
  }

  /// Кодирует любое значение в байты CBOR
  /// Если передан Map, он должен быть Map(String, dynamic) при strictMapTypes=true
  static Uint8List _encode(dynamic value, {bool strictMapTypes = true}) {
    // Проверяем, что если передана Map, то она имеет тип Map<String, dynamic>
    if (strictMapTypes && value is Map && value is! Map<String, dynamic>) {
      throw ArgumentError(
        'CborCodec.encode принимает только Map<String, dynamic>, получено: ${value.runtimeType}',
      );
    }

    final builder = BytesBuilder();
    _encodeValue(value, builder);
    return builder.toBytes();
  }

  /// Декодирует CBOR байты в Dart объекты
  static dynamic _decode(Uint8List bytes, {bool strictMapTypes = true}) {
    final reader = _CborReader(bytes);
    final value = reader.readValue();

    if (strictMapTypes && value is Map && value is! Map<String, dynamic>) {
      throw ArgumentError(
        'CborCodec.decode принимает только Map<String, dynamic>, '
        'получено: ${value.runtimeType}',
      );
    }

    // Если результат карта, убеждаемся что ключи строковые
    if (value is Map) {
      return _ensureStringKeys(value);
    }

    return value;
  }

  /// Рекурсивно кодирует значение в CBOR
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
      // Для IRpcSerializable используем toJson(), который возвращает Map<String, dynamic>
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
        // Для неизвестных типов преобразуем в строку
        _encodeString(value.toString(), builder);
      }
    }
  }

  /// Кодирует null
  static void _encodeNull(BytesBuilder builder) {
    builder.addByte(_getMajorTypeByte(_majorTypeSimple, _simpleValueNull));
  }

  /// Кодирует bool
  static void _encodeBool(bool value, BytesBuilder builder) {
    builder.addByte(_getMajorTypeByte(
      _majorTypeSimple,
      value ? _simpleValueTrue : _simpleValueFalse,
    ));
  }

  /// Кодирует int
  static void _encodeInt(int value, BytesBuilder builder) {
    if (value >= 0) {
      _encodePositiveInt(value, builder);
    } else {
      _encodeNegativeInt(-value - 1, builder);
    }
  }

  /// Кодирует положительное число
  static void _encodePositiveInt(int value, BytesBuilder builder) {
    if (value <= 23) {
      builder.addByte(_getMajorTypeByte(_majorTypeUnsignedInt, value));
    } else if (value <= 0xFF) {
      builder.addByte(_getMajorTypeByte(
        _majorTypeUnsignedInt,
        _additionalInfoOneByteFollow,
      ));
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFF) {
      builder.addByte(_getMajorTypeByte(
        _majorTypeUnsignedInt,
        _additionalInfoTwoByteFollow,
      ));
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFFFFFF) {
      builder.addByte(_getMajorTypeByte(
        _majorTypeUnsignedInt,
        _additionalInfoFourByteFollow,
      ));
      builder.addByte((value >> 24) & 0xFF);
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else {
      builder.addByte(_getMajorTypeByte(
        _majorTypeUnsignedInt,
        _additionalInfoEightByteFollow,
      ));

      // Правильное кодирование 64-битного числа согласно RFC 7049
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

  /// Кодирует отрицательное число
  static void _encodeNegativeInt(int value, BytesBuilder builder) {
    if (value <= 23) {
      builder.addByte(_getMajorTypeByte(_majorTypeNegativeInt, value));
    } else if (value <= 0xFF) {
      builder.addByte(_getMajorTypeByte(
        _majorTypeNegativeInt,
        _additionalInfoOneByteFollow,
      ));
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFF) {
      builder.addByte(_getMajorTypeByte(
        _majorTypeNegativeInt,
        _additionalInfoTwoByteFollow,
      ));
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else if (value <= 0xFFFFFFFF) {
      builder.addByte(_getMajorTypeByte(
        _majorTypeNegativeInt,
        _additionalInfoFourByteFollow,
      ));
      builder.addByte((value >> 24) & 0xFF);
      builder.addByte((value >> 16) & 0xFF);
      builder.addByte((value >> 8) & 0xFF);
      builder.addByte(value & 0xFF);
    } else {
      builder.addByte(_getMajorTypeByte(
        _majorTypeNegativeInt,
        _additionalInfoEightByteFollow,
      ));

      // Правильное кодирование 64-битного числа согласно RFC 7049
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

  /// Кодирует double
  static void _encodeDouble(double value, BytesBuilder builder) {
    // Для float используем IEEE 754 64-bit (Double)
    builder.addByte(_getMajorTypeByte(
      _majorTypeSimple,
      _additionalInfoEightByteFollow,
    ));

    // Конвертируем double в bytes в формате IEEE 754
    final ByteData data = ByteData(8);
    data.setFloat64(0, value, Endian.big); // Используем big-endian по RFC 7049

    // Добавляем байты
    for (int i = 0; i < 8; i++) {
      builder.addByte(data.getUint8(i));
    }
  }

  /// Кодирует строку
  static void _encodeString(String value, BytesBuilder builder) {
    // Кодируем строку как массив UTF-8 байтов
    final utf8Bytes = utf8.encode(value);

    // Стандартное кодирование для строк по RFC 7049
    _encodeLength(_majorTypeTextString, utf8Bytes.length, builder);
    builder.add(utf8Bytes);
  }

  /// Кодирует бинарную строку
  static void _encodeByteString(Uint8List bytes, BytesBuilder builder) {
    _encodeLength(_majorTypeByteString, bytes.length, builder);
    builder.add(bytes);
  }

  /// Кодирует список
  static void _encodeList(List<dynamic> list, BytesBuilder builder) {
    _encodeLength(_majorTypeArray, list.length, builder);
    for (final item in list) {
      _encodeValue(item, builder);
    }
  }

  /// Кодирует карту (словарь)
  static void _encodeMap(Map<dynamic, dynamic> map, BytesBuilder builder) {
    _encodeLength(_majorTypeMap, map.length, builder);

    // RFC 7049 рекомендует сортировать ключи для детерминированного кодирования
    final keys = map.keys.toList()
      ..sort((a, b) {
        // Сначала преобразуем к строкам, а затем сравниваем
        final aString = a.toString();
        final bString = b.toString();
        // Сравниваем побайтово
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
      // Для совместимости всегда кодируем ключи как строки
      _encodeString(key.toString(), builder);
      _encodeValue(map[key], builder);
    }
  }

  /// Кодирует длину
  static void _encodeLength(int majorType, int length, BytesBuilder builder) {
    if (length <= 23) {
      builder.addByte(_getMajorTypeByte(majorType, length));
    } else if (length <= 0xFF) {
      builder.addByte(_getMajorTypeByte(
        majorType,
        _additionalInfoOneByteFollow,
      ));
      builder.addByte(length & 0xFF);
    } else if (length <= 0xFFFF) {
      builder.addByte(_getMajorTypeByte(
        majorType,
        _additionalInfoTwoByteFollow,
      ));
      builder.addByte((length >> 8) & 0xFF);
      builder.addByte(length & 0xFF);
    } else if (length <= 0xFFFFFFFF) {
      builder.addByte(_getMajorTypeByte(
        majorType,
        _additionalInfoFourByteFollow,
      ));
      builder.addByte((length >> 24) & 0xFF);
      builder.addByte((length >> 16) & 0xFF);
      builder.addByte((length >> 8) & 0xFF);
      builder.addByte(length & 0xFF);
    } else {
      builder.addByte(_getMajorTypeByte(
        majorType,
        _additionalInfoEightByteFollow,
      ));
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

  /// Формирует байт заголовка
  static int _getMajorTypeByte(int majorType, int additionalInfo) {
    return (majorType << 5) | (additionalInfo & 0x1F);
  }

  /// Преобразует Map(dynamic, dynamic) в Map(String, dynamic)
  static Map<String, dynamic> _ensureStringKeys(Map<dynamic, dynamic> map) {
    return map.map((key, value) {
      // Рекурсивно обрабатываем вложенные карты
      if (value is Map) {
        value = _ensureStringKeys(value);
      } else if (value is List) {
        value = _processListItems(value);
      }
      return MapEntry(key.toString(), value);
    });
  }

  /// Обрабатывает элементы списка, преобразуя вложенные карты
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

/// Вспомогательный класс для чтения CBOR данных
class _CborReader {
  final Uint8List _bytes;
  int _offset = 0;

  _CborReader(this._bytes);

  /// Читает следующее значение из потока байт
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
        // Для простоты просто пропускаем тег и читаем значение
        _readUnsignedInt(additionalInfo);
        return readValue();
      case CborCodec._majorTypeSimple:
        return _readSimpleValue(additionalInfo);
      default:
        throw FormatException('Unknown CBOR major type: $majorType');
    }
  }

  /// Читает беззнаковое целое число
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
        // Читаем 8 байт как big-endian значение
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

  /// Читает бинарную строку
  Uint8List _readByteString(int additionalInfo) {
    final length = _readLength(additionalInfo);

    if (_offset + length > _bytes.length) {
      throw FormatException('Byte string length exceeds available data');
    }

    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  /// Читает текстовую строку
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

  /// Читает массив
  List<dynamic> _readArray(int additionalInfo) {
    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      final result = <dynamic>[];

      // Читаем элементы до break маркера
      while (true) {
        if (_offset >= _bytes.length) {
          throw FormatException(
              'Unexpected end of CBOR data inside indefinite-length array');
        }

        // Проверяем наличие break маркера
        if (_bytes[_offset] ==
            CborCodec._getMajorTypeByte(
                CborCodec._majorTypeSimple, CborCodec._simpleValueBreak)) {
          _offset++; // Пропускаем break маркер
          break;
        }

        // Читаем элемент
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

  /// Читает карту (словарь)
  Map<String, dynamic> _readMap(int additionalInfo) {
    if (additionalInfo == CborCodec._additionalInfoIndefiniteLength) {
      final result = <String, dynamic>{};

      // Читаем пары ключ-значение до break маркера
      while (true) {
        if (_offset >= _bytes.length) {
          throw FormatException(
              'Unexpected end of CBOR data inside indefinite-length map');
        }

        // Проверяем наличие break маркера
        if (_bytes[_offset] ==
            CborCodec._getMajorTypeByte(
                CborCodec._majorTypeSimple, CborCodec._simpleValueBreak)) {
          _offset++; // Пропускаем break маркер
          break;
        }

        // Читаем пару ключ-значение
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

  /// Читает простое значение
  dynamic _readSimpleValue(int additionalInfo) {
    switch (additionalInfo) {
      case CborCodec._simpleValueFalse:
        return false;
      case CborCodec._simpleValueTrue:
        return true;
      case CborCodec._simpleValueNull:
        return null;
      case CborCodec._simpleValueUndefined:
        // Для Dart undefined аналогичен null
        return null;
      case CborCodec._simpleValueBreak:
        throw FormatException(
            'Unexpected break value outside indefinite-length item');
      case CborCodec._additionalInfoEightByteFollow:
        // IEEE 754 Double
        final byteData = ByteData(8);
        for (int i = 0; i < 8; i++) {
          byteData.setUint8(i, _readByte());
        }
        return byteData.getFloat64(
            0, Endian.big); // Используем big-endian по RFC 7049
      default:
        if (additionalInfo >= 0 && additionalInfo <= 19) {
          // Простые значения 0-19
          return additionalInfo;
        }
        if (additionalInfo == CborCodec._additionalInfoOneByteFollow) {
          // Расширенное простое значение (1 байт)
          return _readByte();
        }
        throw FormatException('Unknown simple value: $additionalInfo');
    }
  }

  /// Читает длину
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

  /// Читает один байт
  int _readByte() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }
    return _bytes[_offset++];
  }
}
