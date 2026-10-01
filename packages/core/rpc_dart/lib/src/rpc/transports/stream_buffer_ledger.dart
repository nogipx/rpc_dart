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
  /// Creates a ledger admitting [limitBytes] and [limitEvents] per stream.
  RpcStreamBufferLedger({required this.limitBytes, required this.limitEvents});

  /// Ceiling on un-consumed bytes held for a single stream.
  final int limitBytes;

  /// Ceiling on un-consumed MESSAGES held for a single stream.
  ///
  /// The byte bound cannot see a zero-copy payload: `bufferedBytes` is 0 for a
  /// `directPayload`, because queuing one costs a pointer for an object the
  /// process already retains. Measured, that is true of exactly one shape — a
  /// queue of objects the application holds anyway costs `-1 MiB` — and false of
  /// the other, where minting one per message put `313 MiB` of payload behind a
  /// paused consumer with nothing charged for it.
  ///
  /// So this counts EVENTS, which is the only quantity that bounds both: an
  /// operator cannot meaningfully set a nominal weight for someone else's object,
  /// and a queue depth needs nothing invented.
  final int limitEvents;

  final Map<int, int> _held = {};
  final Map<int, int> _events = {};
  final Set<int> _failed = {};

  /// Charges [bytes] and one message against [streamId].
  ///
  /// Both dimensions, always: a codec payload has bytes AND is one message, and
  /// whichever ceiling it reaches first is the one that binds.
  RpcBufferAdmission admit(int streamId, int bytes) {
    if (_failed.contains(streamId)) return RpcBufferAdmission.refused;
    final next = (_held[streamId] ?? 0) + bytes;
    final nextEvents = (_events[streamId] ?? 0) + 1;
    if (next > limitBytes || nextEvents > limitEvents) {
      _failed.add(streamId);
      return RpcBufferAdmission.overflowed;
    }
    _held[streamId] = next;
    _events[streamId] = nextEvents;
    return RpcBufferAdmission.admitted;
  }

  /// Drops [bytes] and one message of [streamId]'s charge as its consumer takes
  /// them.
  ///
  /// The EVENT count is released even for a message that carried no bytes, or a
  /// zero-copy stream would be admitted `limitEvents` times and never again.
  void release(int streamId, int bytes) {
    final events = _events[streamId];
    if (events != null) {
      if (events <= 1) {
        _events.remove(streamId);
      } else {
        _events[streamId] = events - 1;
      }
    }
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
    _events.remove(streamId);
    _failed.remove(streamId);
  }

  /// Drops every stream's state.
  void clear() {
    _held.clear();
    _events.clear();
    _failed.clear();
  }

  /// Bytes currently charged to [streamId], for diagnostics and tests.
  int heldFor(int streamId) => _held[streamId] ?? 0;

  /// Un-consumed messages currently charged to [streamId], for diagnostics and
  /// tests.
  int eventsFor(int streamId) => _events[streamId] ?? 0;

  /// How many streams hold a charge, for diagnostics and tests.
  ///
  /// Counts either dimension: a zero-copy stream holds events and no bytes, and
  /// reading `_held` alone reported it as tracking nothing.
  int get trackedStreams => {..._held.keys, ..._events.keys}.length;
}
