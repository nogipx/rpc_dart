// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Wrapper for a numeric value.
class RpcNum extends RpcPrimitiveMessage<num> {
  /// Creates an [RpcNum] wrapping [value].
  const RpcNum(super.value);

  /// Creates RpcNum from JSON.
  factory RpcNum.fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v == null) return const RpcNum(0);
    if (v is num) return RpcNum(v);

    if (v is String) {
      // Attempt to parse as number.
      final asDouble = double.tryParse(v);
      if (asDouble != null) {
        // Convert to int when the value is whole.
        if (asDouble == asDouble.toInt()) {
          return RpcNum(asDouble.toInt());
        }
        return RpcNum(asDouble);
      }
    }

    throw FormatException(
      'RpcNum.fromJson: cannot decode value of type ${v.runtimeType}: $v',
    );
  }

  /// Default codec for [RpcNum].
  static RpcCodec<RpcNum> get codec => RpcCodec<RpcNum>(RpcNum.fromJson);

  @override
  String toString() => value.toString();

  // Arithmetic operators.
  /// Adds [other] to this value.
  RpcNum operator +(Object other) => RpcNum(value + _extractNum(other));

  /// Subtracts [other] from this value.
  RpcNum operator -(Object other) => RpcNum(value - _extractNum(other));

  /// Multiplies this value by [other].
  RpcNum operator *(Object other) => RpcNum(value * _extractNum(other));

  /// Divides this value by [other].
  RpcNum operator /(Object other) => RpcNum(value / _extractNum(other));

  /// Integer-divides this value by [other].
  ///
  /// Only integer `~/` integer is allowed. The int/double distinction is
  /// derived from the RpcNum SUBTYPE (RpcInt vs RpcDouble), because on
  /// dart2js there is a single JS number type and `value is int` returns
  /// true even for whole doubles (e.g. `7.0 is int`). Subtype-based checks
  /// are distinguishable identically on VM and dart2js.
  RpcNum operator ~/(Object other) {
    if (_isDoubleTyped(this) || _isDoubleTyped(other)) {
      throw _comparisonException(type: 'RpcNum', op: '~/');
    }
    final a = value;
    final b = _extractNum(other);
    if (a is int && b is int) {
      return RpcNum(a ~/ b);
    }
    throw _comparisonException(type: 'RpcNum', op: '~/');
  }

  /// Returns true when [o] is known to carry a double value via its runtime
  /// type (RpcDouble or a raw double). For a type-erased plain RpcNum/num
  /// this cannot be determined reliably on dart2js, so it returns false.
  static bool _isDoubleTyped(Object o) {
    if (o is RpcDouble) return true;
    if (o is RpcInt) return false;
    return false;
  }

  /// Returns the remainder of dividing this value by [other].
  RpcNum operator %(Object other) => RpcNum(value % _extractNum(other));

  /// Returns the negation of this value.
  RpcNum operator -() => RpcNum(-value);

  /// Returns true if this value is less than [other].
  bool operator <(Object other) {
    if (other is RpcNum) return value < other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '<');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '<', other: other);
  }

  /// Returns true if this value is greater than [other].
  bool operator >(Object other) {
    if (other is RpcNum) return value > other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '>');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '>', other: other);
  }

  /// Returns true if this value is less than or equal to [other].
  bool operator <=(Object other) {
    if (other is RpcNum) return value <= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcNum', op: '<=');
    }
    throw _unsupportedOperand(type: 'RpcNum', op: '<=', other: other);
  }

  /// Returns true if this value is greater than or equal to [other].
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

/// Wrapper for an integer value.
class RpcInt extends RpcPrimitiveMessage<int> {
  /// Creates an [RpcInt] wrapping [value].
  const RpcInt(super.value);

  /// Creates RpcInt from JSON.
  factory RpcInt.fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v == null) return const RpcInt(0);
    if (v is int) return RpcInt(v);
    if (v is num) return RpcInt(v.toInt());
    if (v is String) {
      final parsed = int.tryParse(v) ?? double.tryParse(v)?.toInt();
      if (parsed != null) return RpcInt(parsed);
    }
    throw FormatException(
      'RpcInt.fromJson: cannot decode value of type ${v.runtimeType}: $v',
    );
  }

  /// Default codec for [RpcInt].
  static RpcCodec<RpcInt> get codec => RpcCodec<RpcInt>(RpcInt.fromJson);

  @override
  String toString() => value.toString();

  // Arithmetic operators.
  /// Adds [other] to this value.
  RpcInt operator +(Object other) => RpcInt(value + _extractInt(other));

  /// Subtracts [other] from this value.
  RpcInt operator -(Object other) => RpcInt(value - _extractInt(other));

  /// Multiplies this value by [other].
  RpcInt operator *(Object other) => RpcInt(value * _extractInt(other));

  /// Integer-divides this value by [other].
  RpcInt operator ~/(Object other) => RpcInt(value ~/ _extractInt(other));

  /// Returns the remainder of dividing this value by [other].
  RpcInt operator %(Object other) => RpcInt(value % _extractInt(other));

  /// Divides this value by [other], returning an [RpcDouble].
  RpcDouble operator /(Object other) => RpcDouble(value / _extractInt(other));

  /// Returns the negation of this value.
  RpcInt operator -() => RpcInt(-value);

  /// Returns true if this value is less than [other].
  bool operator <(Object other) {
    if (other is RpcInt) return value < other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '<');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '<', other: other);
  }

  /// Returns true if this value is greater than [other].
  bool operator >(Object other) {
    if (other is RpcInt) return value > other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '>');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '>', other: other);
  }

  /// Returns true if this value is less than or equal to [other].
  bool operator <=(Object other) {
    if (other is RpcInt) return value <= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcInt', op: '<=');
    }
    throw _unsupportedOperand(type: 'RpcInt', op: '<=', other: other);
  }

  /// Returns true if this value is greater than or equal to [other].
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

/// Wrapper for a double value.
class RpcDouble extends RpcPrimitiveMessage<double> {
  /// Creates an [RpcDouble] wrapping [value].
  const RpcDouble(super.value);

  /// Creates RpcDouble from JSON.
  factory RpcDouble.fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v == null) return const RpcDouble(0.0);
    if (v is double) return RpcDouble(v);
    if (v is num) return RpcDouble(v.toDouble());

    if (v is String) {
      // Attempt to parse as double.
      final asDouble = double.tryParse(v);
      if (asDouble != null) {
        return RpcDouble(asDouble);
      }
    }

    throw FormatException(
      'RpcDouble.fromJson: cannot decode value of type ${v.runtimeType}: $v',
    );
  }

  /// Default codec for [RpcDouble].
  static RpcCodec<RpcDouble> get codec =>
      RpcCodec<RpcDouble>(RpcDouble.fromJson);

  @override
  String toString() => value.toString();

  // Arithmetic operators.
  /// Adds [other] to this value.
  RpcDouble operator +(Object other) =>
      RpcDouble(value + _extractDouble(other));

  /// Subtracts [other] from this value.
  RpcDouble operator -(Object other) =>
      RpcDouble(value - _extractDouble(other));

  /// Multiplies this value by [other].
  RpcDouble operator *(Object other) =>
      RpcDouble(value * _extractDouble(other));

  /// Divides this value by [other].
  RpcDouble operator /(Object other) =>
      RpcDouble(value / _extractDouble(other));

  /// Returns the remainder of dividing this value by [other].
  RpcDouble operator %(Object other) =>
      RpcDouble(value % _extractDouble(other));

  /// Returns the negation of this value.
  RpcDouble operator -() => RpcDouble(-value);

  /// Returns true if this value is less than [other].
  bool operator <(Object other) {
    if (other is RpcDouble) return value < other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '<');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '<', other: other);
  }

  /// Returns true if this value is greater than [other].
  bool operator >(Object other) {
    if (other is RpcDouble) return value > other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '>');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '>', other: other);
  }

  /// Returns true if this value is less than or equal to [other].
  bool operator <=(Object other) {
    if (other is RpcDouble) return value <= other.value;
    if (other is num) {
      throw _comparisonException(type: 'RpcDouble', op: '<=');
    }
    throw _unsupportedOperand(type: 'RpcDouble', op: '<=', other: other);
  }

  /// Returns true if this value is greater than or equal to [other].
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
