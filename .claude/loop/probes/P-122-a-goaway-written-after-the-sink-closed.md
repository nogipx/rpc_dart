---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/upstream_finish_repro.dart
round: 480
commit: 20afaba8
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-122 — a GOAWAY written after the sink closed

## Why it exists

B-35's owner decision left exactly one piece of work: *"file the upstream issue;
that is the only work this lead now has."*

P-40 had already measured the throw, but through `RpcHttp2CallerTransport` —
**the wrong shape for an upstream report**, because a maintainer cannot be asked
to install this library to see their own bug. Both ends here are
`package:http2` and nothing else.

Two companion files, and the split is deliberate:

- `upstream_finish_repro.dart` — the matrix, with the controls. This is the
  bench.
- `upstream_minimal.dart` — the exact text pasted into the issue, kept as a file
  that RUNS rather than a quotation that rots. Re-run it before posting.

## The numbers (round 480)

```
finish(), no streams ever opened     UNCAUGHT IN ZONE  (5 of 5 runs)
finish() after a completed stream    silent
finish() then terminate()            silent
CONTROL: terminate() alone           silent
terminate() with a stream IN FLIGHT  silent        <- added round 483
CONTROL: neither called              silent
```

`Bad state: Cannot add event after closing`, on http2 3.1.0 — which
`dart pub outdated` reports as the LATEST, so it is not already fixed upstream.

**Two corrections to B-35 came out of this.** The trigger is NOT teardown in
general but `finish()` on a connection that never opened a stream — the arms
with traffic are silent. And `finish()` does not merely complete before the
throw, it completes NORMALLY; the invariant is that the error never reaches the
returned future at all, whatever the ordering.

## Measures

Whether anything reaches the `runZonedGuarded` handler, and the
`package:http2` frames of its stack. The stack is the point: it is the
actionable half of an upstream report, and the zone handler is the only place it
survives — the error is not a rejection, so nothing at the call site ever holds
it.

Reading the trace bottom-up gives the cause: `_frameWriter.doneFuture`
(`connection.dart:189`) fires `_terminate`, which runs
`BufferIndicator.markUnBuffered`, which emits the `bufferEmptyEvents` the
outgoing queue listens for (`connection_queues.dart:45-47`); `_trySendMessages`
guards on `!wasTerminated` alone (line 80), which has not been set yet, so the
queued GOAWAY is written to a sink the same path just closed.

## Control

Four arms, two of them named CONTROL, and they do different jobs.

- **`terminate()` alone** and **neither called** are silent, so the harness —
  server, socket, zone — is not itself producing the error.
- **`finish()` after a completed stream** is the sharp one: same teardown, same
  connection type, one stream's worth of traffic different, and silent. It is
  what narrows the claim from "finish() throws" to "finish() throws when there
  was nothing to drain".
- **Five repetitions** of the positive arm, because a teardown race that fires
  once is a report a maintainer cannot act on. 5 of 5 makes it deterministic
  rather than intermittent, and those are different bugs.

## What it establishes, and what it does not

Establishes: the defect is in `package:http2` alone, reproducible without
rpc_dart, deterministic, on the latest published version, with a traced cause.

**Does not establish that rpc_dart reaches it.** That was measured separately and
the answer is no — `close()` RSTs every stream before calling `finish()`, so
finish() has something to drain and returns promptly (rounds 346-347, which could
not make it time out even at a 1 ms budget). This round's own matrix agrees from
the other side: the arm WITH a stream is the silent one. The library's
characterisation test stays as what closes the lead the day the dependency stops.

## Round 483 — the arm added to test somebody else's issue

Before posting, the report was checked against the upstream tracker for a
duplicate. Open issue **#1380** ("How to catch the exception thrown by
`ClientTransportConnection.terminate`?", June 2023, unanswered, no reproduction)
is the same FAMILY — a teardown error neither `try/catch` nor `.catchError` can
hold — with a different error and a different call.

**None of the five arms above could speak to it**, and the reason is worth
keeping: every one of them terminates with the stream already ENDED, which the
harness was changed to do precisely so `finish()` would return. So the sixth arm
drives #1380's own shape — `makeRequest`, `sendData`, no `endStream`, then an
AWAITED `terminate()` with a `try/catch` at the call site, which is what the
reporter describes doing.

It is silent, and nothing is caught at the call site either. So #1380 does not
reproduce here and may well have been fixed since 2023. The report mentions it
as related and **does not claim to explain it** — which is the whole value of
having run the arm.

## A first attempt that read clean and was void

Two arms first printed `TIMED OUT` and then `silent`, which is two statements
about the same arm and only one of them true. The server answered with headers
and never ended the stream, and `makeRequest` left the client half open too, so
`finish()` waited forever for a drain that could not happen — **the arm never
reached the code under test and reported quiet anyway** (L-15). Ending both
halves fixed it; the harness now prints `VOID` rather than `silent` when
`finish()` does not return.

## Reading

rpc_dart_http2 — **the same defect as P-40, rebuilt so it runs WITHOUT us.**
B-35's decision left one task, the upstream report, and a report measured
through `RpcHttp2CallerTransport` asks a maintainer to install this library to
see their own bug. Both ends are `package:http2` here. It sharpened the
finding twice: the trigger is `finish()` on a connection that **never opened a
stream** (every arm with traffic is silent), and `finish()` completes
**normally**, so the invariant is that the error never reaches its future
rather than that it arrives late. 5 of 5 runs, http2 3.1.0 (latest). Two
companion files on purpose — the matrix with the controls, and a minimal
`upstream_minimal.dart` that is the pasted issue text kept as a file that RUNS
rather than a quotation that rots. Its own first version was VOID and says so
