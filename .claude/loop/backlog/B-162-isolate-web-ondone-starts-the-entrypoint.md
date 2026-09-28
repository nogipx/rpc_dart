---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-162 — isolate on web: the worker's onDone fallback starts the user entrypoint on a closing transport

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`onDone: () => start(const <String, dynamic>{})` under the comment "a host that never sends init still has to get its entrypoint started"; onDone fires only when the stream ENDS, so a silent host never triggers it, and when it does fire the entrypoint runs on a dead channel and sends `ready` into it.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart:310-311`.

## Why it matters

The comment's case is not handled; a different case runs user code at the wrong
time.

## Witness a round would build

Close the host before init; does the worker run its entrypoint?

## Fix sketch

Remove the fallback or give it a timer.

## Owner decision

—
