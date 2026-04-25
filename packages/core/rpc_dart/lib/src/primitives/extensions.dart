// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension RpcBoolX on bool {
  /// Wraps this value as an [RpcBool].
  RpcBool get rpc => RpcBool(this);
}

extension RpcNullX on void {
  /// Returns an [RpcNull] instance.
  RpcNull get rpc => RpcNull();
}

extension RpcNumX on num {
  /// Wraps this value as an [RpcNum].
  RpcNum get rpc => RpcNum(this);
}

extension RpcDoubleX on double {
  /// Wraps this value as an [RpcDouble].
  RpcDouble get rpc => RpcDouble(this);
}

extension RpcIntX on int {
  /// Wraps this value as an [RpcInt].
  RpcInt get rpc => RpcInt(this);
}

extension RpcStringX on String {
  /// Wraps this value as an [RpcString].
  RpcString get rpc => RpcString(this);
}
