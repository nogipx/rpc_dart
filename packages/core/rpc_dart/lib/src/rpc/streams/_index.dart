// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../../_internal.dart';
import '../../codec/special_cbor.dart'
    show CborItemLimitException, withCborItemBudget;

part 'base_processor.dart';
part 'base_processor_caller.dart';
part 'base_processor_responder.dart';

part 'bidirectional/caller.dart';
part 'bidirectional/responder.dart';

part 'client/caller.dart';
part 'client/responder.dart';

part 'server/caller.dart';
part 'server/responder.dart';

part 'unary/caller.dart';
part 'unary/responder.dart';
part 'responder_base.dart';

/// Contract for server-side responders that handle a single stream.
abstract interface class IRpcResponder {
  /// The transport-level stream ID for this responder.
  int get id;

  /// Completes when the call has fully finished, however it ended.
  Future<void> get done;

  /// Feeds the responder its stream's messages.
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream);

  /// Closes the responder and releases its resources.
  Future<void> close();
}
