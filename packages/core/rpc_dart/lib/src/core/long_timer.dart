// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

/// A [Timer] that stays correct for durations beyond JavaScript's timer ceiling.
///
/// On the web a Dart [Timer] becomes `setTimeout`, whose delay is a SIGNED
/// 32-BIT millisecond value -- 2,147,483,647 ms, about 24.86 days. dart2js
/// passes the duration straight through, and every JS runtime clamps an
/// overflowing delay to 1 ms rather than rejecting it, so a timer set for a
/// month fires almost immediately. Node says so out loud:
///
///   TimeoutOverflowWarning: 2592000000 does not fit into a 32-bit signed
///   integer. Timeout duration was set to 1.
///
/// That inverts the meaning of a deadline. Measured with the same source on
/// both platforms, checking whether an [RpcCallScope] had closed 120 ms after
/// being given each deadline:
///
///   deadline    VM       dart2js
///   1 hour      open     open
///   24 days     open     open        <- just under the ceiling
///   25 days     open     CLOSED      <- just over it
///   30 days     open     CLOSED
///   1 year      open     CLOSED
///
/// and `grpc-timeout: 720H` -- a legal, peer-supplied 30-day value -- lands in
/// the broken half, so a peer can make a web client or server cancel its own
/// call the moment it starts.
///
/// This re-arms in chunks that fit instead of clamping: a duration under the
/// ceiling costs exactly one ordinary [Timer], and a longer one costs one extra
/// timer per 24.86 days. The deadline itself stays exact.
class RpcLongTimer implements Timer {
  /// Largest delay a JS `setTimeout` accepts, in milliseconds.
  static const int maxChunkMillis = 2147483647;

  /// Creates a timer that fires [callback] after [duration], however long.
  RpcLongTimer(Duration duration, void Function() callback)
    : _callback = callback {
    _arm(duration);
  }

  /// Returns an ordinary [Timer] when [duration] fits, and a chunking one when
  /// it does not, so callers pay nothing for the common case.
  static Timer create(Duration duration, void Function() callback) =>
      duration.inMilliseconds > maxChunkMillis
      ? RpcLongTimer(duration, callback)
      : Timer(duration, callback);

  final void Function() _callback;
  Timer? _timer;
  bool _cancelled = false;
  int _tick = 0;

  void _arm(Duration remaining) {
    if (_cancelled) return;
    if (remaining.inMilliseconds <= maxChunkMillis) {
      _timer = Timer(remaining, () {
        _tick++;
        if (!_cancelled) _callback();
      });
      return;
    }
    const chunk = Duration(milliseconds: maxChunkMillis);
    _timer = Timer(chunk, () => _arm(remaining - chunk));
  }

  @override
  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }

  @override
  bool get isActive => !_cancelled && (_timer?.isActive ?? false);

  @override
  int get tick => _tick;
}
