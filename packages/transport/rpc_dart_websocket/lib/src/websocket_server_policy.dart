// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// A source of connections that bounds what it reads by the server's policy.
///
/// The connections stream is built before the server that consumes it, so the
/// policy is handed over when the server starts listening rather than passed
/// twice. Without the hand-off a limit raised on the server alone left the
/// source at the default, refusing everything between the two.
abstract interface class IRpcWebSocketServerPolicyTarget {
  /// Adopts the [policy] of the server that consumes this source, unless one
  /// was given to the source itself.
  void adoptServerPolicy(RpcSecurityPolicy policy);
}
