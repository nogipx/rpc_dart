// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

extension RpcBoolX on bool {
  RpcBool get rpc => RpcBool(this);
}

extension RpcNullX on void {
  RpcNull get rpc => RpcNull();
}

extension RpcNumX on num {
  RpcNum get rpc => RpcNum(this);
}

extension RpcDoubleX on double {
  RpcDouble get rpc => RpcDouble(this);
}

extension RpcIntX on int {
  RpcInt get rpc => RpcInt(this);
}

extension RpcStringX on String {
  RpcString get rpc => RpcString(this);
}
