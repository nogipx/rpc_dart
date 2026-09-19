// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../_internal.dart';

part 'bool.dart';
part 'list.dart';
part 'null.dart';
part 'num.dart';
part 'string.dart';
part 'extensions.dart';

/// Function type that maps a message key to a human-readable string.
typedef RpcMessageProducer = String Function(String);

/// Base class for all primitive message types.
abstract class RpcPrimitiveMessage<T> implements IRpcSerializable {
  /// The wrapped primitive value.
  final T value;

  /// Creates a primitive message wrapping [value].
  const RpcPrimitiveMessage(this.value);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RpcPrimitiveMessage<T> && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;

  /// Serializes primitive value to JSON-ready map.
  @override
  Map<String, dynamic> toJson() => {'v': value};

  // INTERNAL on both: these are caller mistakes in Dart code that never cross
  // the wire, so the status is a formality — but the type has to pick one now,
  // and picking says which.
  RpcException _comparisonException({
    required String type,
    required String op,
  }) => RpcStatusException(
    RpcStatus.internal,
    'Operation "$op" of $type with primitive type is prohibited. '
    'Use value for comparison.',
  );

  RpcException _unsupportedOperand({
    required String type,
    required String op,
    required Object other,
  }) => RpcStatusException(
    RpcStatus.internal,
    'Unsupported operand type for operation "$op" with $type: ${other.toString()}',
  );
}
