---
round: 572
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-19
bench: P-193 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
severity: S1
---

# Round 572 — reconnect crashed before it stranded anyone

## Target

`B-176` over `B-189`, which was the other candidate: B-189 is a `cost` lead about log and broadcast
noise, below the bar the config sets from round 191 on, while this one claims calls that HANG. The
lead's own witness — "three in-flight server-stream calls, `reconnect()`, time to error per call" —
is what was built, and it found something the lead does not name.

Lens RPC-19: one flag, two lifecycle meanings — here a teardown that runs in the wrong order
against a map its own awaits mutate.

## Hypothesis

`reconnect()` cancels each subscription while `terminate()`'s per-stream errors are still in
flight, so the first consumer is left waiting.

## Before

```
reconnect()
    Unhandled exception:
    Concurrent modification during iteration: _Map len:2.
      RpcHttp2CallerTransport._reconnectOnce  ... :1946
```

**`reconnect()` THROWS with two or more streams in flight**, which the lead does not mention and
which no other round had hit. `_discardConnection` terminates the connection, each ending runs the
inline release, and the release removes its own `_streamSubscriptions` entry — while the loop at
`:1946` iterates that live map across an `await`. The reconnect dies half-torn-down: every map
cleared, no new connection, and the exception handed to whoever called it.

With the iteration fixed, the filed claim appears, exactly as filed:

```
    call 0  STILL WAITING
    call 1  error after 10ms: status 14
    call 2  error after 11ms: status 14
    maps after  1 controllers
```

**The FIRST one**, as the lead says — cancelled before its error arrived, with its stream
controller left behind. Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/b176_reconnect_strands.dart`.

And the same rig on `close()`, which the lead does not name:

```
close()
    call 0  error after 54ms: status 14
    call 1  error after 54ms: status 13
    call 2  error after 54ms: status 13
```

**`close()` strands nobody** — a measured negative — but its answer is MIXED, and that is round
571's split answering "the peer forgot its trailers" for a hang-up this side initiated.

## Mechanism

Three things in one teardown: a live map iterated across awaits; the consumers told nothing before
their subscriptions went; and `_fcOutstanding`, `_fcRefused`, `_resetStreams` carried over to a
connection whose ids start again from scratch.

## After

```
reconnect()   call 0, 1, 2  error after 24ms: status 14    maps after 0 controllers
close()       call 0, 1, 2  error after 62ms: status 14
```

`List.of` on the loop; `_streams.closeAll(error: ...)` before it, which is the argument
`closeAll`'s own doc was written for; the three ledgers cleared; and `_isClosed` added to round
571's `dying` test, so our own hang-up is never reported as a forgetful peer.

## Canary

```
A. the live map restored
     Expected: null
       Actual: ConcurrentModificationError:<Concurrent modification during
               iteration: _Map len:0.>

B. `closeAll` removed entirely
     Expected: every element('status 14')
       Actual: ['STILL WAITING', 'status 14', 'status 14']
```

**Canary B was run twice and the first attempt PASSED, which was the useful part.** Disabling only
the `error:` ARGUMENT — leaving the call — still read three errors, because closing the controller
and the terminate error race and the error won that time. Removing the call is what shows the
stranding. So the two are not separable by this rig: what is witnessed is that `closeAll` must be
called, and the `error:` form is required because the bare form would close a waiting consumer's
stream with a CLEAN END — turning a hang into silent truncation, which is worse.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http2 +275
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2180 / 2180, REUSE compliant
```

## Not fixed

**The `error:` argument has no arm of its own**, as above. It is kept because the alternative form
of a call the leak requires is actively worse, not because a test fails without it.

**`close()`'s `closeAll()` is still bare.** Measured as not stranding anyone, so there is nothing
to fix there on this rig; if its race ever resolves the other way the consumer gets a clean end.
Named rather than changed.

**The crash's blast radius is not measured.** What a half-torn-down transport does next — every map
cleared, `_disconnected` true, no connection — was not driven; the round fixed the crash rather
than charting what it leaves behind.

**`_fcRefused` and `_resetStreams` carrying over has no witness.** `fcOutstanding` read 0 in every
arm, so the clears are by symmetry with `_fcForget`, and that is stated rather than claimed.

## Links

Lead `../backlog/B-176-http2-reconnect-strands-subscribers.md` — CLOSED.
Round `571-the-retry-that-charged-three-times.md` — whose split this round corrects with
`_isClosed`.
Bench `../probes/P-193-what-in-flight-consumers-are-told-at-a-teardown.md` — new.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [572]`.
Lesson: none. `canary.md` item 7 — a canary that unexpectedly passes means the test is wrong — is
what caught the `error:`-only ablation, and it is already written.
