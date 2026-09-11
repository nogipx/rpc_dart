---
status: open
round: 347
commit: e78bd8e2
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/terminate_rejects_into_the_zone.dart
reason: "no reachable user-visible failure was established — the transport's own close path does not reach the state, measured — and every fix for it is a design decision about zone-guarding a dependency's internal throws"
---

# B-35 — package:http2's finish() throws into the zone, and no call site can catch it

## Measured

```
unawaited(conn.terminate()) after finish()        StateError in the zone
conn.terminate().catchError(...) after finish()   StateError in the zone
conn.finish() and NOTHING else                    StateError in the zone
```

`StateError: Bad state: Cannot add event after closing`, thrown **after**
`finish()`'s own future has completed. It is not a rejection: a `.catchError` on
the returned future does not see it, which is what the second row shows.

Three states that do NOT throw, so it is specific rather than ambient:
terminate() on a live connection, terminate() twice, terminate() after the
socket was destroyed.

## Why it is a lead and not an incident

The transport's own `close()` does not reach it. Measured over a real
connect / unary call / `close()` / `close()` again, inside `runZonedGuarded`:
nothing escapes. `close()` RSTs every stream before calling `finish()`, so
finish() has nothing to drain and returns promptly — rounds 346 and 347 failed
to make it time out even with the budget forced to 1 ms and to zero.

So the hazard is real and the path to it from this library is not established.

## What the code already says

`rpc_http2_caller_transport.dart`, above the close path:

> terminate() ... is the right primitive on a dead connection anyway --
> finish() on one throws from package:http2 into the root zone.

Correct, and round 347 still misread it — see the round record. The `try/catch`
around `await _connection.finish().timeout(...)` is right for what it CAN catch;
the zone throw is out of reach of any handler at the call site.

## What a fix would have to decide

Only a zone contains it. Running the connection inside `runZonedGuarded` changes
where a genuine transport error surfaces for the application, which is a
behaviour decision rather than a repair — and it would swallow errors this
library currently lets through on purpose. The alternative is upstream: report it
to package:http2.

Do NOT "fix" it at the call site. Two attempts measured, both ineffective: a
`try/catch` around `unawaited(...)` (the shipped form — it can only see a
synchronous throw) and `.catchError` on `terminate()` (terminate is not the
source).

## Owner decision

**Not yet taken, and one is needed before anything is built.** The choice is
between three, and none is a repair:

1. leave it — nothing in this library reaches the state, measured;
2. run the connection in `runZonedGuarded`, which contains it and also changes
   where genuine transport errors surface for the application;
3. report it upstream to `package:http2` and leave the comment as the record.

Round 347 recommends (1) plus the characterisation test that is already in, and
(3) if the owner wants it off the list permanently.

## Guarded by

`packages/transport/rpc_dart_http2/test/finish_throws_into_the_zone_test.dart` —
asserts the dependency still behaves this way, so the day it stops, this lead
closes.
