// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

/// Обертка для числового значения
class RpcNum extends RpcPrimitiveMessage<num> {
  const RpcNum(super.value);

  /// Создает RpcNum из JSON
  factory RpcNum.fromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v == null) return const RpcNum(0);
      if (v is num) return RpcNum(v);

      // Пробуем преобразовать в число
      final asDouble = double.tryParse(v.toString());
      if (asDouble != null) {
        // Если это целое число, преобразуем в int
        if (asDouble == asDouble.toInt()) {
          return RpcNum(asDouble.toInt());
        }
        return RpcNum(asDouble);
      }

      return const RpcNum(0);
    } catch (e) {
      return const RpcNum(0);
    }
  }

  static RpcCodec<RpcNum> get codec => RpcCodec<RpcNum>(RpcNum.fromJson);

  @override
  String toString() => value.toString();

  // Арифметические операторы
  RpcNum operator +(Object other) => RpcNum(value + _extractNum(other));
  RpcNum operator -(Object other) => RpcNum(value - _extractNum(other));
  RpcNum operator *(Object other) => RpcNum(value * _extractNum(other));
  RpcNum operator /(Object other) => RpcNum(value / _extractNum(other));
  RpcNum operator ~/(Object other) {
    final a = value;
    final b = _extractNum(other);
    if (a is int && b is int) {
      return RpcNum(a ~/ b);
    }
    throw _comparisonException(type: 'RpcNum', op: '~/');
  }

  RpcNum operator %(Object other) => RpcNum(value % _extractNum(other));
  RpcNum operator -() => RpcNum(-value);

  bool operator <(Object other) {
    if (other is RpcNum) return value < other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '<');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '<', other: other);
  }

  bool operator >(Object other) {
    if (other is RpcNum) return value > other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '>');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '>', other: other);
  }

  bool operator <=(Object other) {
    if (other is RpcNum) return value <= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '<=');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '<=', other: other);
  }

  bool operator >=(Object other) {
    if (other is RpcNum) return value >= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '>=');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '>=', other: other);
  }

  @override
  bool operator ==(Object other) {
    if (other is RpcNum) return value == other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '==');
    }
    return false;
  }

  @override
  int get hashCode => value.hashCode;

  num _extractNum(Object other) {
    if (other is RpcNum) return other.value;
    if (other is RpcInt) return other.value;
    if (other is RpcDouble) return other.value;
    if (other is num) return other;
    throw _unsupportedOperand(type: 'RpcNum', op: 'extract', other: other);
  }
}

/// Обертка для целочисленного значения
class RpcInt extends RpcPrimitiveMessage<int> {
  const RpcInt(super.value);

  /// Создает RpcInt из JSON
  factory RpcInt.fromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v == null) return const RpcInt(0);
      if (v is int) return RpcInt(v);
      if (v is num) return RpcInt(v.toInt());
      return RpcInt(int.tryParse(v.toString()) ?? 0);
    } catch (e) {
      return const RpcInt(0);
    }
  }

  static RpcCodec<RpcInt> get codec => RpcCodec<RpcInt>(RpcInt.fromJson);

  @override
  String toString() => value.toString();

  // Арифметические операторы
  RpcInt operator +(Object other) => RpcInt(value + _extractInt(other));
  RpcInt operator -(Object other) => RpcInt(value - _extractInt(other));
  RpcInt operator *(Object other) => RpcInt(value * _extractInt(other));
  RpcInt operator ~/(Object other) => RpcInt(value ~/ _extractInt(other));
  RpcInt operator %(Object other) => RpcInt(value % _extractInt(other));
  RpcDouble operator /(Object other) => RpcDouble(value / _extractInt(other));
  RpcInt operator -() => RpcInt(-value);

  bool operator <(Object other) {
    if (other is RpcInt) return value < other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '<');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '<', other: other);
  }

  bool operator >(Object other) {
    if (other is RpcInt) return value > other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '>');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '>', other: other);
  }

  bool operator <=(Object other) {
    if (other is RpcInt) return value <= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '<=');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '<=', other: other);
  }

  bool operator >=(Object other) {
    if (other is RpcInt) return value >= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '>=');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '>=', other: other);
  }

  @override
  bool operator ==(Object other) {
    if (other is RpcInt) return value == other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '==');
    }
    return false;
  }

  @override
  int get hashCode => value.hashCode;

  int _extractInt(Object other) {
    if (other is RpcInt) return other.value;
    if (other is RpcNum) return other.value.toInt();
    if (other is RpcDouble) return other.value.toInt();
    if (other is int) return other;
    if (other is num) return other.toInt();
    throw _unsupportedOperand(type: 'RpcInt', op: 'extract', other: other);
  }
}

/// Обертка для дробного числа
class RpcDouble extends RpcPrimitiveMessage<double> {
  const RpcDouble(super.value);

  /// Создает RpcDouble из JSON
  factory RpcDouble.fromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v == null) return const RpcDouble(0.0);
      if (v is double) return RpcDouble(v);
      if (v is num) return RpcDouble(v.toDouble());

      // Пробуем преобразовать в double
      final asDouble = double.tryParse(v.toString());
      if (asDouble != null) {
        return RpcDouble(asDouble);
      }

      return const RpcDouble(0.0);
    } catch (e) {
      return const RpcDouble(0.0);
    }
  }

  static RpcCodec<RpcDouble> get codec =>
      RpcCodec<RpcDouble>(RpcDouble.fromJson);

  @override
  String toString() => value.toString();

  // Арифметические операторы
  RpcDouble operator +(Object other) =>
      RpcDouble(value + _extractDouble(other));
  RpcDouble operator -(Object other) =>
      RpcDouble(value - _extractDouble(other));
  RpcDouble operator *(Object other) =>
      RpcDouble(value * _extractDouble(other));
  RpcDouble operator /(Object other) =>
      RpcDouble(value / _extractDouble(other));
  RpcDouble operator %(Object other) =>
      RpcDouble(value % _extractDouble(other));
  RpcDouble operator -() => RpcDouble(-value);

  bool operator <(Object other) {
    if (other is RpcDouble) return value < other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '<');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '<', other: other);
  }

  bool operator >(Object other) {
    if (other is RpcDouble) return value > other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '>');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '>', other: other);
  }

  bool operator <=(Object other) {
    if (other is RpcDouble) return value <= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '<=');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '<=', other: other);
  }

  bool operator >=(Object other) {
    if (other is RpcDouble) return value >= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '>=');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '>=', other: other);
  }

  @override
  bool operator ==(Object other) {
    if (other is RpcDouble) return value == other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '==');
    }
    return false;
  }

  @override
  int get hashCode => value.hashCode;

  double _extractDouble(Object other) {
    if (other is RpcDouble) return other.value;
    if (other is RpcNum) return other.value.toDouble();
    if (other is RpcInt) return other.value.toDouble();
    if (other is double) return other;
    if (other is num) return other.toDouble();
    throw _unsupportedOperand(type: 'RpcDouble', op: 'extract', other: other);
  }
}
