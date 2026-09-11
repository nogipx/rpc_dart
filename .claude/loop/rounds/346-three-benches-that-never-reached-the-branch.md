---
round: 346
verdict: INCONCLUSIVE
packages: [rpc_dart_http2]
lens: RPC-13
bench: none
commit: yes
---

# Round 346 — three benches that never reached the branch

## Target

Round 342's own code, re-read: it added `unawaited(close())` inside a `catch`.
Following that down, `close()` turns out to be guarded at every `await` — and
its LAST line is not:

```dart
try {
  unawaited(_connection.terminate());
} catch (e2) {
  _logger?.warning('Error closing the HTTP/2 connection: $e2');
}
```

`unawaited` detaches the future, so the `catch` can only see a SYNCHRONOUS throw
from calling `terminate()`. A rejected future reaches the zone with no handler.

## Hypothesis

RPC-13's shape, and reachable: this line runs only when the graceful
`finish()` has already failed or timed out — a dead or half-open connection,
which is precisely the case it exists for. The file knows the failure mode two
comments up: *"finish() on one throws from package:http2 into the root zone."*

## Before

Nothing measured, because no bench reached the line. Three attempts, each
`runZonedGuarded` with a stream in flight, counting unhandled zone errors:

```
                                        terminate() branch   unhandled
1  peer sockets destroyed               not reached          0
2  + branch reachability instrumented   not reached          0
3  peer goes SILENT without closing     not reached          0
```

**Attempt 1's zero was unreadable and attempt 2 is what showed it.** A silent arm
that never entered the branch prints exactly what one that entered and stayed
quiet prints. Adding the reachability read — off the transport's own
`'Graceful HTTP/2 shutdown did not complete'` warning, so no instrumentation of
the library — turned two meaningless zeros into two honest "not reached".

Why each failed:

- **destroying the peer** makes `finish()` complete with an error, which the
  `try` takes. The 2 s timeout never fires, so the branch is skipped.
- **pausing the pipes** was meant to produce a half-open path where GOAWAY goes
  out and no drain returns. It did not fire the timeout either, and this round
  did not establish why.

## Mechanism

Not established. The reading is solid — the `unawaited` inside the `try` is real
and the comment above it names the exact failure class — but whether
`_connection.terminate()`'s future can reject, and whether anything reaches that
line in practice, is unmeasured.

## After

No change. Nothing was proven, so nothing was fixed.

## Canary

None. There is no fix to ablate.

## Gate

No library change; `git diff --stat packages` empty.

## Not fixed

**The verdict is INCONCLUSIVE and the budget is why.** Three bench rebuilds is
the limit the config sets, and the rule it sets with it is that a bench which
could not see the defect makes the verdict INCONCLUSIVE rather than CLEAN —
however many times it was rebuilt. Calling this CLEAN would be the exact error
round 343 avoided by accident.

**The approach to try next, and it is not a fourth variation of the peer.** Stop
provoking the timeout from outside and force it: `_gracefulCloseTimeout` is a
`static const Duration` at `rpc_http2_caller_transport.dart:191`. Temporarily set
it to a millisecond and the branch is taken on every close, dead peer or not —
then the question narrows to the one that matters, which is whether
`terminate()`'s future rejects. That is instrumentation of the mechanism, which
the config permits in a probe, rather than a fourth attempt to reproduce the
weather.

## Links

RPC-13, and round 329's finding about why the analyzer is no help here:
`unawaited_futures` fires only inside `async` bodies, and this is one — but
`unawaited(...)` is the documented way to silence it, so the lint reads this line
as correct by construction.

> **An arm that reports zero has to prove it could have reported one.** The first
> bench here produced two clean zeros and would have supported a CLEAN verdict;
> the only reason it did not is that the second added a reachability read and
> both zeros turned out to mean "the code under test never ran".
