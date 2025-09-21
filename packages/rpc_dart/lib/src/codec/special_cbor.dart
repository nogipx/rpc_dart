// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart' show IRpcSerializable;

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
    final writer = _FastCborWriter();
    writer.writeMap(value);
    return writer.toBytes();
  }

  /// Декодирует CBOR байты в Dart объекты
  static Map<String, dynamic> decode(Uint8List bytes) {
    final reader = _FastCborReader(bytes);
    return reader.readMap();
  }

  /// Небезопасное кодирование любого значения в байты CBOR
  /// НЕ проверяет типы Map - принимает любые Map типы
  /// Используется для тестирования и специальных случаев
  static Uint8List encodeUnsafe(dynamic value) {
    return _encode(value, strictMapTypes: false);
  }

  /// Небезопасное декодирование CBOR байтов
  /// Возвращает dynamic вместо строго типизированного Map(String, dynamic)
  /// Используется для тестирования и специальных случаев
  static dynamic decodeUnsafe(Uint8List bytes) {
    final reader = _CborReader(bytes);
    return reader.readValue();
  }

  /// Кодирует любое значение в байты CBOR
  /// Если передан Map, он должен быть Map(String, dynamic) при strictMapTypes=true
  static Uint8List _encode(dynamic value, {bool strictMapTypes = true}) {
    // Проверяем, что если передана Map, то она имеет тип Map<String, dynamic>
    if (strictMapTypes && value is Map && value is! Map<String, dynamic>) {
      throw ArgumentError(
        'CborCodec.encode принимает только Map<String, dynamic>, получено несовместимый тип Map',
      );
    }

    final builder = BytesBuilder();
    _encodeValue(value, builder);
    return builder.toBytes();
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
    builder.addByte(
      _getMajorTypeByte(
        _majorTypeSimple,
        value ? _simpleValueTrue : _simpleValueFalse,
      ),
    );
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
    builder.addByte(
      _getMajorTypeByte(_majorTypeSimple, _additionalInfoEightByteFollow),
    );

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
            'Unexpected end of CBOR data inside indefinite-length array',
          );
        }

        // Проверяем наличие break маркера
        if (_bytes[_offset] ==
            CborCodec._getMajorTypeByte(
              CborCodec._majorTypeSimple,
              CborCodec._simpleValueBreak,
            )) {
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
            'Unexpected end of CBOR data inside indefinite-length map',
          );
        }

        // Проверяем наличие break маркера
        if (_bytes[_offset] ==
            CborCodec._getMajorTypeByte(
              CborCodec._majorTypeSimple,
              CborCodec._simpleValueBreak,
            )) {
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
          'Unexpected break value outside indefinite-length item',
        );
      case CborCodec._additionalInfoEightByteFollow:
        // IEEE 754 Double
        final byteData = ByteData(8);
        for (int i = 0; i < 8; i++) {
          byteData.setUint8(i, _readByte());
        }
        return byteData.getFloat64(
          0,
          Endian.big,
        ); // Используем big-endian по RFC 7049
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

/// OPTIMIZED: Быстрый CBOR ридер для Map(String, dynamic)
/// Убирает лишние проверки и конвертации типов
class _FastCborReader {
  final Uint8List _bytes;
  int _offset = 0;

  _FastCborReader(this._bytes);

  /// Читает Map(String, dynamic) напрямую (без промежуточных конвертаций)
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

  /// Быстрое чтение карты с оптимизациями
  Map<String, dynamic> _readMapFast(int additionalInfo) {
    final length = _readLength(additionalInfo);
    final result = <String, dynamic>{};

    for (int i = 0; i < length; i++) {
      // Читаем ключ (всегда строка)
      final key = _readStringFast();
      // Читаем значение
      final value = _readValueFast();
      result[key] = value;
    }

    return result;
  }

  /// Быстрое чтение строки без кеширования
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

  /// Быстрое чтение значения с оптимизациями
  dynamic _readValueFast() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }

    final byte = _bytes[_offset++];
    final majorType = byte >> 5;
    final additionalInfo = byte & 0x1F;

    // Оптимизируем для наиболее частых типов
    switch (majorType) {
      case CborCodec._majorTypeUnsignedInt:
        return _readUnsignedIntFast(additionalInfo);
      case CborCodec._majorTypeNegativeInt:
        return -_readUnsignedIntFast(additionalInfo) - 1;
      case CborCodec._majorTypeTextString:
        // Откатываемся на 1 байт назад и читаем строку
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

  /// Быстрое чтение unsigned int
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

  /// Быстрое чтение byte string
  Uint8List _readByteStringFast(int additionalInfo) {
    final length = _readLength(additionalInfo);

    if (_offset + length > _bytes.length) {
      throw FormatException('Byte string length exceeds available data');
    }

    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  /// Быстрое чтение массива
  List<dynamic> _readArrayFast(int additionalInfo) {
    final length = _readLength(additionalInfo);
    final result = <dynamic>[];

    for (int i = 0; i < length; i++) {
      result.add(_readValueFast());
    }

    return result;
  }

  /// Быстрое чтение простых значений
  dynamic _readSimpleValueFast(int additionalInfo) {
    switch (additionalInfo) {
      case CborCodec._simpleValueFalse:
        return false;
      case CborCodec._simpleValueTrue:
        return true;
      case CborCodec._simpleValueNull:
        return null;
      case CborCodec._additionalInfoEightByteFollow:
        // IEEE 754 Double - inline для скорости
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

  /// Быстрое чтение длины
  int _readLength(int additionalInfo) {
    if (additionalInfo < 24) {
      return additionalInfo;
    }
    return _readUnsignedIntFast(additionalInfo);
  }

  /// Быстрое чтение одного байта (inline)
  int _readByteFast() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of CBOR data');
    }
    return _bytes[_offset++];
  }
}

/// OPTIMIZED: Быстрый CBOR writer для Map(String, dynamic)
/// Убирает лишние проверки и конвертации типов
class _FastCborWriter {
  final BytesBuilder _builder = BytesBuilder();

  /// Возвращает закодированные байты
  Uint8List toBytes() => _builder.toBytes();

  /// Кодирует Map(String, dynamic) в байты CBOR
  void writeMap(Map<String, dynamic> value) {
    _writeLength(CborCodec._majorTypeMap, value.length);

    // RFC 7049 рекомендует сортировать ключи для детерминированного кодирования
    final keys = value.keys.toList()
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
      _writeString(key.toString());
      _writeValue(value[key]);
    }
  }

  /// Кодирует значение в байты CBOR
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
      // Для IRpcSerializable используем toJson(), который возвращает Map<String, dynamic>
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
        // Для неизвестных типов преобразуем в строку
        _writeString(value.toString());
      }
    }
  }

  /// Кодирует null
  void _writeNull() {
    _builder.addByte(
      _getMajorTypeByte(CborCodec._majorTypeSimple, CborCodec._simpleValueNull),
    );
  }

  /// Кодирует bool
  void _writeBool(bool value) {
    _builder.addByte(
      _getMajorTypeByte(
        CborCodec._majorTypeSimple,
        value ? CborCodec._simpleValueTrue : CborCodec._simpleValueFalse,
      ),
    );
  }

  /// Кодирует int
  void _writeInt(int value) {
    if (value >= 0) {
      _writePositiveInt(value);
    } else {
      _writeNegativeInt(-value - 1);
    }
  }

  /// Кодирует положительное число
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

      // Правильное кодирование 64-битного числа согласно RFC 7049
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

  /// Кодирует отрицательное число
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

      // Правильное кодирование 64-битного числа согласно RFC 7049
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

  /// Кодирует double
  void _writeDouble(double value) {
    // Для float используем IEEE 754 64-bit (Double)
    _builder.addByte(
      _getMajorTypeByte(
        CborCodec._majorTypeSimple,
        CborCodec._additionalInfoEightByteFollow,
      ),
    );

    // Конвертируем double в bytes в формате IEEE 754
    final ByteData data = ByteData(8);
    data.setFloat64(0, value, Endian.big); // Используем big-endian по RFC 7049

    // Добавляем байты
    for (int i = 0; i < 8; i++) {
      _builder.addByte(data.getUint8(i));
    }
  }

  /// Кодирует строку
  void _writeString(String value) {
    // Кодируем строку как массив UTF-8 байтов
    final utf8Bytes = utf8.encode(value);

    // Стандартное кодирование для строк по RFC 7049
    _writeLength(CborCodec._majorTypeTextString, utf8Bytes.length);
    _builder.add(utf8Bytes);
  }

  /// Кодирует бинарную строку
  void _writeByteString(Uint8List bytes) {
    _writeLength(CborCodec._majorTypeByteString, bytes.length);
    _builder.add(bytes);
  }

  /// Кодирует список
  void _writeList(List<dynamic> list) {
    _writeLength(CborCodec._majorTypeArray, list.length);
    for (final item in list) {
      _writeValue(item);
    }
  }

  /// Кодирует карту (словарь)
  void _writeMap(Map<dynamic, dynamic> map) {
    _writeLength(CborCodec._majorTypeMap, map.length);

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
      _writeString(key.toString());
      _writeValue(map[key]);
    }
  }

  /// Кодирует длину
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

  /// Формирует байт заголовка
  int _getMajorTypeByte(int majorType, int additionalInfo) {
    return (majorType << 5) | (additionalInfo & 0x1F);
  }
}
