// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'transport.dart';

/// Per-stream delivery for a transport that multiplexes many calls.
///
/// A transport exposes every incoming message on one broadcast stream, and
/// `getMessagesForStream(id)` has to hand each caller only its own. Doing that
/// by filtering the broadcast costs one predicate per active stream per
/// message, and lets a stream-scoped error reach every subscriber; this gives
/// each stream its own controller instead.
///
/// Transport-authoring API, like `BufferedBroadcastController` beside it. It
/// owns ONLY the per-stream half — the transport keeps its own broadcast and
/// decides what to put on it.
///
/// What breaks if a transport hand-rolls this instead: the four that did each
/// had to remember that a subscriber may cancel before end-of-stream (leaking a
/// controller per abandoned call), that [close] must complete the streams a
/// consumer is still awaiting, and that an error for stream 3 must not surface
/// on stream 5. Three invariants, four copies.
class RpcStreamRouter {
  final Map<int, StreamController<RpcTransportMessage>> _controllers = {};

  /// Live per-stream controllers. Exposed so a transport can report it in
  /// `health()`, where growth that never returns to a baseline is the leak
  /// signal.
  int get length => _controllers.length;

  /// Whether [streamId] currently has a subscriber-facing controller.
  bool contains(int streamId) => _controllers.containsKey(streamId);

  /// The stream for [streamId], creating its controller on first call.
  ///
  /// Repeated calls return the SAME stream rather than a second controller: the
  /// endpoint layers may ask more than once for one call, and a second
  /// controller would silently receive nothing.
  ///
  /// `onCancel` drops the entry, so a consumer that walks away before
  /// end-of-stream does not leave the controller behind.
  Stream<RpcTransportMessage> operator [](int streamId) {
    final existing = _controllers[streamId];
    if (existing != null) return existing.stream;
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _controllers.remove(streamId),
    );
    _controllers[streamId] = ctl;
    return ctl.stream;
  }

  /// Delivers [message] to its stream, closing that stream on end-of-stream.
  ///
  /// The transport calls this AFTER putting the message on its own broadcast;
  /// the ordering matters only in that both must happen for every message.
  void add(RpcTransportMessage message) {
    final ctl = _controllers[message.streamId];
    if (ctl != null && !ctl.isClosed) ctl.add(message);
    if (message.isEndOfStream) {
      final ended = _controllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }

  /// Delivers an error to ONE stream's subscriber.
  ///
  /// Stream-scoped by construction, which is the point: a transport that
  /// reports a parse failure on the shared broadcast hands it to every
  /// concurrent call, so an error on stream 3 surfaces on stream 5.
  void addError(int streamId, Object error, [StackTrace? stackTrace]) {
    final ctl = _controllers[streamId];
    if (ctl != null && !ctl.isClosed) ctl.addError(error, stackTrace);
  }

  /// Drops [streamId]'s controller without closing it.
  ///
  /// For a caller that has already torn the stream down itself and does not
  /// want the close to reach a consumer that cancelled.
  StreamController<RpcTransportMessage>? remove(int streamId) =>
      _controllers.remove(streamId);

  /// Closes every remaining stream, reporting [error] first where it returns
  /// one.
  ///
  /// [error] is given the stream id and may return null, which is the case that
  /// matters: a transport closing under its callers wants to tell the ones that
  /// were IN FLIGHT why their call ended, and to stay silent for the rest. A
  /// plain close leaves the first group's `await` completing with nothing.
  void closeAll({Object? Function(int streamId)? error}) {
    for (final entry in _controllers.entries) {
      final ctl = entry.value;
      if (ctl.isClosed) continue;
      final reason = error?.call(entry.key);
      if (reason != null) ctl.addError(reason);
      unawaited(ctl.close());
    }
    _controllers.clear();
  }
}
