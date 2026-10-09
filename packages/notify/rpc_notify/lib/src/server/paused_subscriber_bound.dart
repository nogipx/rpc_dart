// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/notify_event.dart';

/// Delivers [source] to one listener, holding at most [maxEvents] events and
/// [maxBytes] bytes for it while it is paused. Past either, new events are
/// dropped and [onDrop] is called once per event.
///
/// The repositories hand out broadcast streams, and a paused subscription to
/// a broadcast stream buffers every event with no limit. The server's
/// response stream pauses when the subscriber stops granting flow-control
/// credit, so without this a remote subscriber that stops reading makes the
/// server hold everything published to its topic.
///
/// The source itself is never paused.
Stream<NotifyEvent> boundWhilePaused(
  Stream<NotifyEvent> source, {
  required int maxEvents,
  required int maxBytes,
  void Function()? onDrop,
}) {
  final queue = ListQueue<(NotifyEvent, int)>();
  var queuedBytes = 0;
  var paused = false;
  StreamSubscription<NotifyEvent>? inner;
  late final StreamController<NotifyEvent> out;

  void drain() {
    while (!paused && queue.isNotEmpty) {
      final (event, size) = queue.removeFirst();
      queuedBytes -= size;
      out.add(event);
    }
  }

  out = StreamController<NotifyEvent>(
    sync: true,
    onListen: () {
      inner = source.listen(
        (event) {
          if (!paused && queue.isEmpty) {
            out.add(event);
            return;
          }
          final size = approxEventBytes(event);
          if (queue.length >= maxEvents || queuedBytes + size > maxBytes) {
            onDrop?.call();
            return;
          }
          queue.add((event, size));
          queuedBytes += size;
        },
        onError: out.addError,
        onDone: () {
          // What is queued is dropped with the stream; it was never sent.
          queue.clear();
          unawaited(out.close());
        },
      );
    },
    onPause: () => paused = true,
    onResume: () {
      paused = false;
      drain();
    },
    onCancel: () {
      queue.clear();
      return inner?.cancel();
    },
  );
  return out.stream;
}

/// Approximate size of [event]: the UTF-16 code units of every string in its
/// topic and payload, keys included, plus 8 for each other scalar.
int approxEventBytes(NotifyEvent event) =>
    event.topic.length + 16 + _approxJsonBytes(event.payload);

int _approxJsonBytes(Object? value) => switch (value) {
  null => 0,
  final String s => s.length,
  final Map<dynamic, dynamic> m => m.entries.fold(
    0,
    (sum, e) => sum + _approxJsonBytes(e.key) + _approxJsonBytes(e.value),
  ),
  final Iterable<dynamic> items => items.fold(
    0,
    (sum, item) => sum + _approxJsonBytes(item),
  ),
  final IRpcSerializable s => _approxJsonBytes(s.toJson()),
  _ => 8,
};
