---
status: closed (round 572)
round: 572
commit: 09aa8e60
release: breaking
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: P-193
reason: "bench — CONFIRMED and larger than filed: before the stranding the lead describes, `reconnect()` THREW `Concurrent modification during iteration` with two or more streams in flight and died half-torn-down. Both fixed; `close()` measured as NOT an instance"
---

# B-176 — http2 caller: reconnect() cancels stream subscriptions without telling their consumers

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_discardConnection` then `await subscription.cancel()` for each; `terminate()` delivers per-stream errors asynchronously, so the first subscription is gone before its error arrives and its consumer waits out its deadline; `_streams`, `_fcOutstanding`, `_fcRefused`, `_resetStreams` are not cleared; parked `sendMessage` calls return as if sent.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1779-1799`.

## Why it matters

Calls in flight at reconnect hang instead of failing fast.

## Witness a round would build

Three in-flight server-stream calls, `reconnect()`; time to error per call.

## Fix sketch

Fail each stream's router entry with UNAVAILABLE before cancelling; clear the
maps; make parked sends throw.

## Outcome (round 572) — confirmed, and bigger than filed

`../rounds/572-reconnect-crashed-before-it-stranded-anyone.md`. Bench `P-193`.

```
BEFORE anything else:
  reconnect()   Unhandled exception: Concurrent modification during iteration:
                _Map len:2.   ... _reconnectOnce :1946

with that fixed, the filed claim:
  call 0  STILL WAITING
  call 1  error after 10ms: status 14
  call 2  error after 11ms: status 14
  maps after  1 controllers

after:
  call 0, 1, 2  error after 24ms: status 14    0 controllers
```

**`reconnect()` THREW with two or more streams in flight** — not in this lead, and no round had hit
it. `_discardConnection` terminates the connection, each ending runs the inline release, the release
removes its own `_streamSubscriptions` entry, and the loop iterated that live map across an `await`.
The reconnect died half-torn-down: every map cleared, no new connection, the exception handed to its
caller.

Then the stranding, exactly as filed and on the FIRST call, with its stream controller left behind.

**`close()` is a measured NEGATIVE** — it strands nobody. But it read a MIXED `14/13/13` for one
event, which was round 571's status split answering "the peer forgot its trailers" for a hang-up
this side initiated; `_isClosed` in that test settles it.

Fixed: `List.of` on the loop, `closeAll(error:)` before it, `_fcOutstanding`/`_fcRefused`/
`_resetStreams` cleared, `_isClosed` in the dying test. The lead's last clause — parked sends
returning as if sent — was already fixed by rounds 568 and by `dispose()` waking them.

**The `error:` argument has no arm of its own**: disabling only the argument still read three
errors, because closing the controller and the terminate error race. It is kept because the bare
form would close a waiting consumer's stream with a CLEAN END, which is worse than the hang.

## Owner decision

—
