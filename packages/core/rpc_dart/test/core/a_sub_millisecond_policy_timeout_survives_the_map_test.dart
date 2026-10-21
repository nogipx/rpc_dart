// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The policy map carries durations in milliseconds and reads 0 as disabled,
/// so a positive duration under 1 ms must not come back as 0.
void main() {
  test('a sub-millisecond timeout stays enabled through toMap/fromMap', () {
    const policy = RpcSecurityPolicy(
      halfOpenStreamTimeout: Duration(microseconds: 500),
      initialSendWindowGrace: Duration(microseconds: 1),
    );

    final back = RpcSecurityPolicy.fromMap(policy.toMap());

    expect(back.halfOpenStreamTimeout, const Duration(milliseconds: 1));
    expect(back.initialSendWindowGrace, const Duration(milliseconds: 1));
  });

  test('a disabled timeout stays disabled', () {
    const policy = RpcSecurityPolicy(
      halfOpenStreamTimeout: null,
      initialSendWindowGrace: null,
    );

    final back = RpcSecurityPolicy.fromMap(policy.toMap());

    expect(back.halfOpenStreamTimeout, isNull);
    expect(back.initialSendWindowGrace, isNull);
  });
}
