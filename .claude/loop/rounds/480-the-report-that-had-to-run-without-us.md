---
round: 480
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-13
bench: P-122 — new
commit: yes
---

# Round 480 — the report that had to run without us

## Target

B-35, whose owner decision names exactly one remaining task: *"file the upstream
issue; that is the only work this lead now has."* No behaviour change here was
decided, and none was made.

DEFERRED rather than FIXED because the defect is in a dependency and the fix is
theirs. The deliverable is a report, and the round's job was to make it one a
maintainer can act on without argument.

## Hypothesis

P-40 measured the throw through `RpcHttp2CallerTransport`. That is the wrong
shape for an upstream issue: it asks a maintainer to install this library to see
their own bug, and it leaves open whether rpc_dart is doing something unusual.
A report needs `package:http2` on both ends and nothing else.

## Before

Rebuilt that way, the finding **sharpened twice, and both are corrections to
this repository's own record.**

```
finish(), no streams ever opened     UNCAUGHT IN ZONE  (5 of 5 runs)
finish() after a completed stream    silent
finish() then terminate()            silent
CONTROL: terminate() alone           silent
CONTROL: neither called              silent
```

1. **The trigger is narrower than B-35 said.** Not teardown in general —
   `finish()` on a connection that never opened a stream. Every arm with traffic
   on it is silent, which is the opposite of what "finish() has something to
   drain" would predict.
2. **`finish()` completes NORMALLY**, printing after the uncaught error. B-35
   said the throw arrives "after finish()'s own future has completed", which
   described the rpc_dart-mediated ordering. The invariant that actually holds,
   and the one the report makes, is that the error never reaches the returned
   future at all — whatever the ordering.

Verified on http2 3.1.0, which `dart pub outdated` reports as the LATEST, so the
report is not about a version already superseded.

## Mechanism

Not ours to change; traced so the report names a cause rather than a symptom.
Reading the stack bottom-up, the termination path emits the event that drives
the queue that writes to the sink termination just closed:

```
finish() enqueues GOAWAY, closes the frame writer's sink (nothing to drain)
  -> _frameWriter.doneFuture.whenComplete   connection.dart:189
  -> _terminate -> BufferIndicator.markUnBuffered   async_utils.dart:29
  -> bufferEmptyEvents listener             connection_queues.dart:45-47
  -> _trySendMessages, guarded on !wasTerminated ALONE   line 80
  -> writeGoawayFrame into a closed sink -> StateError
```

`wasTerminated` has not been set yet at step 5, so the only guard passes. The
throw is synchronous inside a `.listen()` callback with no `onError`, which is
why it reaches the zone and why no call site can hold it.

## After

No code changed in this repository. The deliverable is `B-35`'s new section —
the issue text, with the trace, the causal reading, the version, and a minimal
reproduction.

The lead keeps `decided by owner`, on B-38's precedent: that one waits on the
owner booting a simulator, this one on the owner pasting an issue, and neither
is a judgement a round can make. Both therefore keep appearing under "owner
decisions not yet carried out", which is accurate — one named action each, with
nothing left to do before it.

## Canary

Not applicable in the usual form: nothing was fixed, so nothing can be switched
off. What stands in for it is the **control column**, which is doing the same
job — `finish() after a completed stream` is the same teardown on the same
connection type with one stream's worth of traffic different, and it is silent.
That is what turns "finish() throws" into a claim narrow enough to act on.

The five repetitions are the second half. A teardown race that fires once is a
report a maintainer cannot act on; 5 of 5 makes it deterministic, and
deterministic and intermittent are different bugs.

## A first attempt that read clean and was void

Worth recording because it nearly shipped into the issue. Two arms printed
`TIMED OUT` and then `silent` — two statements about one arm, only one of them
true. The server sent headers and never ended the stream, and `makeRequest` left
the client's half open too, so `finish()` waited for a drain that could not
happen: **the arm never reached the code under test and reported quiet anyway**
(L-15). Had the contradiction not been printed on the same line, "finish() with
an open stream is silent" would have gone upstream as a fact.

Ending both halves fixed it, and the harness now prints `VOID` rather than
`silent` when `finish()` does not return.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS over 15 packages. No library code changed; the
gate is run because the round is committed, not because it is at risk.

## Not fixed

**The issue is not POSTED.** That is the whole remaining step and it is
deliberately not taken: publishing to an external tracker is outward-facing and
irreversible-ish, and the owner's name goes on it. Everything up to the paste is
done and verified.

**No behaviour change here, as decided.** The characterisation test stays what it
is — the thing that closes this lead the day the dependency stops throwing. Do
not re-derive the zone guard: it was proposed, decided and withdrawn with a
reason, and nothing this round found makes the state reachable from this library.
This round's matrix in fact agrees from the other side — the arm WITH a stream is
the silent one, and `close()` always has a stream to RST.

## Links

- B-35 — the lead, now carrying the report text
- P-122 — the bench; P-40 is the older rpc_dart-mediated measurement it replaces
  for this purpose, and does not become invalid
- L-15 — a void arm reads like a clean one. Second time in two rounds, and here
  it would have put a false sentence in someone else's issue tracker
- RPC-13 — an async error with no handler reaches the zone
