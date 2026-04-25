// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'base_processor.dart';

part 'bidirectional/caller.dart';
part 'bidirectional/responder.dart';

part 'client/caller.dart';
part 'client/responder.dart';

part 'server/caller.dart';
part 'server/responder.dart';

part 'unary/caller.dart';
part 'unary/responder.dart';

/// Contract for server-side responders that handle a single stream.
abstract interface class IRpcResponder {
  /// The transport-level stream ID for this responder.
  int get id;
}
