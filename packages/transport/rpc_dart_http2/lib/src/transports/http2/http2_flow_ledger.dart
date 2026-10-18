// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

import 'rpc_http2_common.dart';

/// One stream's share of the [Http2FlowLedger]: what its consumer holds and
/// whether the call has been failed for holding too much.
///
/// It lives in the transport's per-stream record, so it goes when the record
/// does.
final class Http2FlowAccount {
  /// Bytes delivered to the consumer but not yet reported consumed.
  int outstanding = 0;

  /// The call has already been failed for overrunning the window, so the
  /// overrun is acted on once.
  bool refused = false;

  /// The consumer reports consumption itself, through
  /// [IRpcFlowCredit.returnFlowCredit]. Only the responder sets it.
  bool deferred = false;

  /// Nothing is charged, refused or deferred.
  bool get isClear => outstanding == 0 && !refused && !deferred;

  /// Drops the charge, the refusal and the deferral.
  void forget() {
    outstanding = 0;
    refused = false;
    deferred = false;
  }
}

/// The un-consumed payload bound both HTTP/2 transports keep per call.
///
/// Reading never stops: the bound fails the CALL past [window] instead, see
/// the transports' notes on why pausing an h2 stream costs the connection.
/// Bytes are charged as they are delivered and discharged as the consumer
/// takes them; [onOverrun] runs once per call, when the bytes already waiting
/// exceed the window.
final class Http2FlowLedger {
  /// A ledger reading [policy]'s window.
  ///
  /// [accountOf] finds a stream's account; a stream without one is not
  /// charged. [isMetered] says whether a delivery to that stream is charged at
  /// all: only a consumer that reports back can discharge.
  Http2FlowLedger({
    required RpcSecurityPolicy policy,
    required Http2FlowAccount? Function(int streamId) accountOf,
    required bool Function(int streamId, Http2FlowAccount account) isMetered,
    required void Function(int streamId, int outstanding) onOverrun,
  }) : window = unconsumedWindowFor(policy),
       _accountOf = accountOf,
       _isMetered = isMetered,
       _onOverrun = onOverrun;

  /// How much un-consumed payload one call may hold.
  final int window;

  final Http2FlowAccount? Function(int streamId) _accountOf;
  final bool Function(int streamId, Http2FlowAccount account) _isMetered;
  final void Function(int streamId, int outstanding) _onOverrun;

  /// Charges [bytes] delivered to [streamId] and runs [onOverrun] the first
  /// time the stream is past the window.
  ///
  /// Past it by what was ALREADY waiting, not by the message that just
  /// arrived: one message is delivered whole and cannot be consumed before it
  /// is here, so counting it refused every message larger than the window
  /// from a consumer reading as fast as it could.
  void charge(int streamId, int bytes) {
    if (bytes <= 0) return;
    final account = _accountOf(streamId);
    if (account == null || !_isMetered(streamId, account)) return;
    final before = account.outstanding;
    final now = before + bytes;
    account.outstanding = now;
    if (before <= window || account.refused) return;
    account.refused = true;
    _onOverrun(streamId, now);
  }

  /// Credits [bytes] [streamId]'s consumer has taken.
  void discharge(int streamId, int bytes) {
    if (bytes <= 0) return;
    final account = _accountOf(streamId);
    if (account == null) return;
    final left = account.outstanding - bytes;
    account.outstanding = left <= 0 ? 0 : left;
  }

  /// [source], discharging each message's payload as the consumer takes it.
  ///
  /// `map` is lazy, so a consumer that stops pulling stops discharging, which
  /// is what lets the budget fill and the call be failed.
  Stream<RpcTransportMessage> metered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) => source.map((message) {
    discharge(streamId, message.payload?.length ?? 0);
    return message;
  });

  /// Drops [streamId]'s charge, refusal and deferral.
  void forget(int streamId) => _accountOf(streamId)?.forget();
}
