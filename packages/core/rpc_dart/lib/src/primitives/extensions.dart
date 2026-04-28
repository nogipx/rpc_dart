// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Extension to wrap [bool] as [RpcBool].
extension RpcBoolX on bool {
  /// Wraps this value as an [RpcBool].
  RpcBool get rpc => RpcBool(this);
}

/// Extension to wrap `void` as [RpcNull].
extension RpcNullX on void {
  /// Returns an [RpcNull] instance.
  RpcNull get rpc => RpcNull();
}

/// Extension to wrap [num] as [RpcNum].
extension RpcNumX on num {
  /// Wraps this value as an [RpcNum].
  RpcNum get rpc => RpcNum(this);
}

/// Extension to wrap [double] as [RpcDouble].
extension RpcDoubleX on double {
  /// Wraps this value as an [RpcDouble].
  RpcDouble get rpc => RpcDouble(this);
}

/// Extension to wrap [int] as [RpcInt].
extension RpcIntX on int {
  /// Wraps this value as an [RpcInt].
  RpcInt get rpc => RpcInt(this);
}

/// Extension to wrap [String] as [RpcString].
extension RpcStringX on String {
  /// Wraps this value as an [RpcString].
  RpcString get rpc => RpcString(this);
}
