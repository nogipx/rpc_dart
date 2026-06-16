// Audit findings 1 & 2: client buffer behavior in log_output.dart.
//
// Finding 1 -- unbounded re-buffer on send failure (log_output.dart:84-93):
//   if (_connected && _caller != null) {
//     _caller!.send(wrapped).then((_) {}, onError: (Object _) {
//       _buffer.addLast(wrapped);          // <-- NO trim to bufferSize
//     });
//   } else {
//     _buffer.addLast(wrapped);
//     while (_buffer.length > bufferSize) { _buffer.removeFirst(); }  // trim only here
//   }
// Once connected, _connected is only reset inside _closeTransport(), which is
// NOT called on a send failure -- only on connect/handshake failure. So under
// sustained send failures while still "_connected", every record takes the
// onError branch and _buffer grows past bufferSize without bound.
//
// Finding 2 -- _flushBuffer fire-and-forget loss/reorder (log_output.dart:162-168):
//   while (_buffer.isNotEmpty && _connected && _caller != null) {
//     final record = _buffer.removeFirst();
//     unawaited(_caller!.send(record).catchError((_) => const LogCollectorAck()));
//   }
// removeFirst() happens BEFORE the send resolves, and the error is swallowed, so
// a send that fails mid-flush silently drops that record. Ordering is also not
// guaranteed because all sends are launched concurrently (fire-and-forget).
//
// WHY NOT UNIT-TESTABLE via the public API:
//   * _buffer, _connected and _caller are all private with no getter.
//   * The bug in finding 1 is a pure memory-growth leak: the over-buffered
//     records are never flushed (no reconnect is triggered by a send failure),
//     so there is NO observable output difference -- only heap growth, which
//     Dart's test harness cannot assert on without reflection/heap APIs.
//   * Finding 2's loss/reorder requires forcing specific sends to fail DURING
//     an in-progress _flushBuffer on a real connected caller. There is no public
//     seam to inject a failing caller, and LogCollectorOutput owns its transport
//     internally (constructed in _connect from the uri), so failures cannot be
//     scheduled deterministically per-record.
//
// Both are CONFIRMED-by-code-reading (the trim is genuinely absent in the
// onError branch; the flush genuinely removes-then-fires-and-swallows), but they
// are reported as NOT-TESTABLE at the unit level. Fixing the API to expose a
// buffer length getter or accept an injectable caller/transport would make them
// testable.

import 'package:test/test.dart';

void main() {
  test(
    'findings 1 & 2 are NOT unit-testable via public API (see file header)',
    () {},
    skip:
        'NOT-TESTABLE: private _buffer/_connected/_caller, no observable output '
        'for the unbounded-growth leak, no injection seam for per-record send '
        'failures. Confirmed by code reading instead.',
  );
}
