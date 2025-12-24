// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

part 'bool.dart';
part 'list.dart';
part 'null.dart';
part 'num.dart';
part 'string.dart';
part 'extensions.dart';

typedef RpcMessageProducer = String Function(String);

/// Base class for all primitive message types.
abstract class RpcPrimitiveMessage<T> implements IRpcSerializable {
  final T value;

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

  RpcException _comparisonException({
    required String type,
    required String op,
  }) =>
      RpcException(
        'Operation "$op" of $type with primitive type is prohibited. '
        'Use value for comparison.',
      );

  RpcException _unsupportedOperand({
    required String type,
    required String op,
    required Object other,
  }) =>
      RpcException(
        'Unsupported operand type for operation "$op" with $type: ${other.toString()}',
      );
}
