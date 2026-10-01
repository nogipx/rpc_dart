---
status: closed (round 557)
round: 557
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-178 — http2 caller: `_discardConnection` says runZonedGuarded, does try/catch

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The doc says it runs inside `runZonedGuarded` rather than behind a `catchError`; the body is `try { connection.terminate(); } catch`, and the Future `terminate()` returns is neither awaited nor handled — an async error from it reaches the root zone.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1691-1702`. Related: B-35 (closed by the
owner) on `finish()`; this is a different call site.

## Why it matters

A potential process kill on reconnect; a comment that describes code that is not
there.

## Witness a round would build

Reconnect while the old connection's socket errors.

## Fix sketch

Attach `.catchError` (or actually zone-guard it) and fix the comment.

## Outcome (round 557) — severity REFUTED, prose CONFIRMED and fixed

`../../rounds/557-the-comment-named-a-zone-that-was-not-there.md`. Bench
`../../probes/P-182-where-terminate-s-error-lands.md`.

```
  CONTROL healthy, future discarded            nothing escaped
  CONTROL healthy, future awaited              nothing escaped
  socket destroyed, future DISCARDED           nothing escaped
  socket destroyed, future AWAITED in try      nothing escaped
  POSITIVE CONTROL finish() on a live socket   ZONE: Bad state: Cannot add event after closing
  POSITIVE CONTROL finish() then terminate()   ZONE: Bad state: Cannot add event after closing
```

**No process kill.** Dropping `terminate()`'s future costs nothing observable at either state the
method can be in, so the fix sketch would have attached a handler for an error that does not arrive.
`TransportConnection.terminate` IS declared `Future terminate([int?, String?])` — the shape this lead
read off the signature is real, which is what made it cheap to report and cheap to be wrong about.

**The prose half holds.** The comment's reason is true and belongs to `finish()`, a call this method
does not make — it exists precisely to avoid it. Round 347 lost a round to the same confusion, so the
comment now names which call it is about and points at the test holding both halves.

**The two `terminate()` arms are now in `finish_throws_into_the_zone_test`**, beside the `finish()`
one. That placement is deliberate: four silent rows mean "terminate is safe" only if something in the
same rig is known to escape, and the probe's first version had no working control — its peer was a
bare TCP listener, against which `finish()` never completed at all.

Not covered: `_discardConnection` driven through `reconnect()` (the arms call `terminate()` at the
http2 layer in the two states it can be in); package:http2 2.3.1, which the workspace also resolves
and whose `finish()` behaviour already differed once (B-53); and the transport's other
`terminate()`/`finish()` call sites, which were not swept.

## Owner decision

—
