// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Sizes of a channel transport's per-stream flow-control maps, read from its
/// health report.
Future<Map<String, int>> flowStateSizes(IRpcTransport transport) async =>
    (await transport.health()).details['flowControl']! as Map<String, int>;

/// A channel transport's connection-pool send credit, read from its health
/// report; null while the peer has advertised no connection window.
Future<int?> flowConnectionCredit(IRpcTransport transport) async =>
    (await transport.health()).details['connectionCredit'] as int?;
