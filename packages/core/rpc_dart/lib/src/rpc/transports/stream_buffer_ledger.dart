// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// What [RpcStreamBufferLedger.admit] decided about one message.
enum RpcBufferAdmission {
  /// Charged; the message may be queued.
  admitted,

  /// This message crossed the limit. The caller fails the stream once.
  overflowed,

  /// The stream is already failed; drop without re-reporting.
  refused,
}

/// Bounds how many bytes one stream may hold un-consumed in a queue.
///
/// Separate from flow control, and deliberately so: the window paces DATA and
/// metadata walks past it — `sendMetadata` spends no window and credit is
/// returned on payload bytes only, both on purpose, because a control frame
/// that cannot be sent deadlocks the stream it is ending. Measured in round
/// 282: 4000 metadata frames, 32 MiB, none paced and no bound fired. So the
/// limit here is a BUFFER bound, which is also how HTTP/2 bounds headers
/// (`SETTINGS_MAX_HEADER_LIST_SIZE`, not the window).
///
/// Fails THE STREAM, never the connection: a peer flooding one call must not
/// take down the others sharing the socket.
final class RpcStreamBufferLedger {
  /// Creates a ledger admitting [limitBytes] per stream.
  RpcStreamBufferLedger({required this.limitBytes});

  /// Ceiling on un-consumed bytes held for a single stream.
  final int limitBytes;

  final Map<int, int> _held = {};
  final Set<int> _failed = {};

  /// Charges [bytes] against [streamId].
  RpcBufferAdmission admit(int streamId, int bytes) {
    if (_failed.contains(streamId)) return RpcBufferAdmission.refused;
    final next = (_held[streamId] ?? 0) + bytes;
    if (next > limitBytes) {
      _failed.add(streamId);
      return RpcBufferAdmission.overflowed;
    }
    _held[streamId] = next;
    return RpcBufferAdmission.admitted;
  }

  /// Drops [bytes] of [streamId]'s charge as its consumer takes them.
  void release(int streamId, int bytes) {
    final held = _held[streamId];
    if (held == null) return;
    final left = held - bytes;
    if (left <= 0) {
      _held.remove(streamId);
    } else {
      _held[streamId] = left;
    }
  }

  /// Drops every trace of [streamId]; called when its call ends.
  void forget(int streamId) {
    _held.remove(streamId);
    _failed.remove(streamId);
  }

  /// Drops every stream's state.
  void clear() {
    _held.clear();
    _failed.clear();
  }

  /// Bytes currently charged to [streamId], for diagnostics and tests.
  int heldFor(int streamId) => _held[streamId] ?? 0;

  /// How many streams hold a charge, for diagnostics and tests.
  int get trackedStreams => _held.length;
}
