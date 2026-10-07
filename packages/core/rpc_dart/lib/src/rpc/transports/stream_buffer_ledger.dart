// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// What [RpcStreamBufferLedger.admit] decided about one message.
enum RpcBufferAdmission {
  /// Charged; the message may be queued.
  admitted,

  /// This message crossed the limit. The caller fails the stream once.
  overflowed,

  /// This message crossed the CONNECTION total; the stream is failed as for
  /// [overflowed].
  overflowedConnection,

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
  /// Creates a ledger admitting [limitBytes] and [limitEvents] per stream, and
  /// [limitTotalBytes] across all of them.
  RpcStreamBufferLedger({
    required this.limitBytes,
    required this.limitEvents,
    this.limitTotalBytes,
  });

  /// Ceiling on un-consumed bytes summed over every stream, or null for none.
  ///
  /// Without it the per-stream bound multiplies by the stream count: a peer
  /// ignoring flow control parks [limitBytes] on each stream it opens.
  final int? limitTotalBytes;

  int _total = 0;

  /// Un-consumed bytes held across all streams, for diagnostics and tests.
  int get totalBytes => _total;

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

  /// Charges [bytes] and [events] messages against [streamId].
  ///
  /// Both dimensions: a codec payload has bytes AND is one message, and
  /// whichever ceiling it reaches first is the one that binds. A bare metadata
  /// frame is passed as no message, because the sender's message credit does
  /// not count it either; its bytes still bound it.
  RpcBufferAdmission admit(int streamId, int bytes, {int events = 1}) {
    if (_failed.contains(streamId)) return RpcBufferAdmission.refused;
    final next = (_held[streamId] ?? 0) + bytes;
    final nextEvents = (_events[streamId] ?? 0) + events;
    if (next > limitBytes || nextEvents > limitEvents) {
      _failed.add(streamId);
      return RpcBufferAdmission.overflowed;
    }
    final totalLimit = limitTotalBytes;
    if (totalLimit != null && _total + bytes > totalLimit) {
      _failed.add(streamId);
      return RpcBufferAdmission.overflowedConnection;
    }
    _held[streamId] = next;
    if (nextEvents > 0) _events[streamId] = nextEvents;
    _total += bytes;
    return RpcBufferAdmission.admitted;
  }

  /// Charges [bytes] held by another layer to the connection total only; false,
  /// and nothing charged, when they would cross it.
  bool chargeTotal(int bytes) {
    final totalLimit = limitTotalBytes;
    if (totalLimit != null && _total + bytes > totalLimit) return false;
    _total += bytes;
    return true;
  }

  /// Returns [bytes] a [chargeTotal] took.
  void releaseTotal(int bytes) {
    _total -= bytes;
  }

  /// Drops [bytes] and [events] messages of [streamId]'s charge as its
  /// consumer takes them; [events] matches what [admit] was given.
  ///
  /// The EVENT count is released even for a message that carried no bytes, or a
  /// zero-copy stream would be admitted `limitEvents` times and never again.
  void release(int streamId, int bytes, {int events = 1}) {
    final queued = _events[streamId];
    if (queued != null && events > 0) {
      if (queued <= events) {
        _events.remove(streamId);
      } else {
        _events[streamId] = queued - events;
      }
    }
    final held = _held[streamId];
    if (held == null) return;
    final left = held - bytes;
    if (left <= 0) {
      _held.remove(streamId);
      _total -= held;
    } else {
      _held[streamId] = left;
      _total -= bytes;
    }
  }

  /// Drops every trace of [streamId]; called when its call ends.
  void forget(int streamId) {
    _total -= _held.remove(streamId) ?? 0;
    _events.remove(streamId);
    _failed.remove(streamId);
  }

  /// Drops every stream's state.
  void clear() {
    _held.clear();
    _events.clear();
    _failed.clear();
    _total = 0;
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
