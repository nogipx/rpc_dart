---
file: packages/core/rpc_dart/.dart_tool/probe/b204_where_the_message_goes.dart
round: 622
commit: a8af9626
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid (round 622)
---

# P-224 — where a streamed message goes

## Why it exists

B-204: about 4.4 us per server-stream message through the endpoints, in a
bridge stack none of whose layers had been varied.

## The harness

Two files. `b204_the_floor_under_the_bridges.dart` is P-147's stream with no
endpoint: the server frames and sends 10 000 `'x'` messages with the same codec,
and the client parses and decodes them off `getMessagesForStream`. That is
transport, framing and codec only. `b204_where_the_message_goes.dart` runs
P-147's endpoint stream 60 x 10 000 under the VM's own profiler (`fvm dart
--profiler`), reads the samples through the VM service the probe opens on
itself, and aggregates them by top frame, library and function.

## The numbers (round 622)

```
P-147 at HEAD (endpoints)          min 4.351  median 4.439 us/message
floor (transport+framing+codec)    min 1.567  median 1.571 us/message

top frame by library, 2462 samples
  dart:async        51.5 %   (+ dart:async-patch 6.8 %)
  rpc_dart          23.7 %
  dart:_compact_hash 6.8 %
  typed_data, core, convert, internal   the rest
largest single frames: handleValueCallback 8.0 %, _RootZone.runUnaryGuarded
  5.0 %, _microtaskLoop 4.6 %, _Future._propagateToListeners 3.8 %
```

## Measures

How much of a streamed message the endpoint layers cost, and in what.

## Control

The floor arm: the same messages, codec and transport with the endpoints
removed.
