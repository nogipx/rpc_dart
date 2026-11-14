// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Two-dimensional accounting for a single queue. It owns no payloads.
final class RpcBufferBudget {
  /// Null disables that dimension. Sizes must use one consistent unit.
  RpcBufferBudget({this.limitBytes, this.limitEvents});

  /// Maximum admitted pending bytes, when bounded.
  final int? limitBytes;

  /// Maximum admitted pending events, when bounded.
  final int? limitEvents;
  int _bytes = 0;
  int _events = 0;

  /// Bytes admitted and not yet released.
  int get bytes => _bytes;

  /// Events admitted and not yet released.
  int get events => _events;

  /// Admits both dimensions atomically, or changes neither on overflow.
  bool admit(int bytes, {int events = 1}) {
    if (bytes < 0 || events < 0) {
      throw ArgumentError('buffer charges must be non-negative');
    }
    final nextBytes = _bytes + bytes;
    final nextEvents = _events + events;
    if ((limitBytes != null && nextBytes > limitBytes!) ||
        (limitEvents != null && nextEvents > limitEvents!)) {
      return false;
    }
    _bytes = nextBytes;
    _events = nextEvents;
    return true;
  }

  /// Releases a charge, clamping repeated or excessive releases at zero.
  void release(int bytes, {int events = 1}) {
    if (bytes < 0 || events < 0) {
      throw ArgumentError('buffer releases must be non-negative');
    }
    _bytes = bytes >= _bytes ? 0 : _bytes - bytes;
    _events = events >= _events ? 0 : _events - events;
  }

  /// Releases all accounting.
  void clear() {
    _bytes = 0;
    _events = 0;
  }
}
