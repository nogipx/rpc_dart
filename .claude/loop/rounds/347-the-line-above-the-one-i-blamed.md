---
round: 347
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-13
bench: P-42 — new
commit: yes
---

# Round 347 — the line above the one I blamed

## Target

Round 346's own "what to try next": stop provoking the close timeout from
outside and force it, so the `unawaited(_connection.terminate())` branch is
taken and the question narrows to whether `terminate()` rejects.

## Hypothesis

`unawaited` detaches the future from the `try` around it, so a rejection from
`terminate()` reaches the zone unhandled. RPC-13's shape.

## Before

Forcing the timeout did not work either — `_gracefulCloseTimeout` set to 1 ms,
then to `Duration.zero`, and the branch still was not taken. The reason is in a
comment I had read past, at `:187`:

> close() has already RST'd every stream still open locally by the time it calls
> `finish()`, so a healthy connection finishes in milliseconds.

With nothing to drain, `finish()` wins the race against any timeout. That is
design, not luck, and it is why rounds 346 and 347 both failed to reach the line.

So the question was asked directly instead — does `terminate()` reject? — over
the four connection states the branch can produce:

```
live connection             no rejection
terminate() twice           no rejection
socket destroyed first      no rejection
finish() then terminate()   REJECTED -> StateError: Cannot add event after closing
```

The rejecting row is the branch's exact order, so this looked settled.

## Mechanism

It was not. The fix — `.catchError` on the terminate future — was written,
witnessed, and the witness went RED:

```
the guarded form does NOT reach the zone
  Expected: empty
    Actual: [StateError: Bad state: Cannot add event after closing]
```

`.catchError` cannot see it, so it is not a rejection of that future at all.
Narrowing once more, to `finish()` and nothing after it:

```
unawaited(terminate()) after finish()        StateError in the zone
terminate().catchError(...) after finish()   StateError in the zone
finish() and NOTHING else                    StateError in the zone
```

**`finish()` is the source.** It throws AFTER its own future has completed, so
no handler at the call site — `try/catch`, `.catchError`, `unawaited` or not —
can see it. `terminate()` was never involved; the fourth row of the earlier
table was `finish()`'s throw arriving while terminate happened to be in flight.

The transport's own comment says this, two lines above the one I blamed:
*"finish() on one throws from package:http2 into the root zone."* I read it,
quoted it in round 346 as supporting evidence, and still chased the line below.

## After

**Reverted.** The library is byte-identical to where round 346 left it. Shipping
the `.catchError` would have been a fix measured not to work — the
"belief without behaviour" failure round 341 was about, committed knowingly.

Kept instead: `finish_throws_into_the_zone_test.dart`, which characterises the
dependency so the next reader does not spend a round on it, plus a GUARD that
the transport's own close stays silent.

## Canary

The witness for the discarded fix is the canary, and it is why the fix was
discarded: red with `.catchError` in place. The kept test's first case is red by
construction if `package:http2` ever stops throwing here, which is the condition
that closes B-35.

## Gate

No library change; `git diff packages/.../lib` empty, verified before writing
the record.

## Not fixed

**B-35**, with the full measurement. No reachable user-visible failure was
established: the transport's close path does not reach the state, measured over
connect / call / close / close-again inside `runZonedGuarded`. And every fix is
a design decision — only a zone contains a throw that arrives outside the future,
and zone-guarding changes where genuine transport errors surface for the
application. The lead says explicitly not to attempt a call-site fix, with both
failed attempts named.

## Links

RPC-13. Round 346 named the right next step and it worked — the branch was
forced open, and what came out was that the branch was never the problem.

> **A comment that names the mechanism is not the same as having read it.** The
> file said "finish() ... throws into the root zone". Round 346 quoted that line
> as evidence FOR suspecting `terminate()` on the line below, and round 347 spent
> three measurements arriving at what it already said. Quoting prose is not
> reading it.
