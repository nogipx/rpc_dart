---
round: 403
verdict: DEFERRED
packages: [rpc_dart_websocket, rpc_dart]
lens: RPC-25
bench: P-88 — reused
commit: yes
---

# Round 403 — the drain that only waits

## Target

The question round 402 could not answer, with the bench it said would answer it.
402 marked P-88 BROKEN and named the repair: a load with NO gap, so
`drainUntilIdle`'s instantaneous count can never read zero and the poll must
spend its whole budget on both transports. Then admission is the only variable
left.

## Hypothesis

`RpcWebSocketServer._drain` merely expires where `RpcHttp2Server._drain`
converges, because only the latter can tell a connected peer to stop opening
streams.

## Before

P-88 repaired: eight parked server-streams held open across the drain, plus
four lanes of unary calls throughout.

```
transport   stop took   before   SERVED after   refused after
websocket    3006 ms      164        1347             3
http2        3016 ms      118           4           514
```

Both now spend the full 3 s, which is the repair working — the gap is gone and
neither can exit early. **337x more work admitted after shutdown began.**

Against 402's numbers, where the same question read `websocket 112 ms / 70` and
`http2 8 ms / 6` at one load and the reverse at another, this is what a bench
that can see its mechanism looks like: the two columns that matter are three
orders of magnitude apart and the direction does not depend on load.

## Mechanism

Confirmed. The http2 server sends GOAWAY before polling and its own doc says
that is what separates converging from expiring. WebSocket has no GOAWAY, and
this server has no substitute — so `stop(drainTimeout:)` stops accepting new
CONNECTIONS and then simply waits, serving everything an already-connected peer
asks for.

**The damage is not the waiting.** When the budget expires the endpoints close,
so a call admitted at 2.9 s into a 3 s drain is killed at 3.0 s: the calls most
likely to be cut mid-flight are the ones the server accepted after it had
decided to shut down. That is what graceful shutdown exists to prevent, and a
rolling deploy reaches it every time.

**And the mechanism already exists one layer down.**
`responder_pipeline.dart:592` rejects a new stream with UNAVAILABLE while
`_respIsDraining` is set, and lets existing ones run — the rpc-level GOAWAY,
already written, already tested, used by neither server.

## After

n/a — deferred, not fixed.

## Why it is DEFERRED and not FIXED

The only public route to that flag is `RpcEndpointBase.drain()`, which also
cancels every active context with reason `server draining` — the opposite of
what `stop(drainTimeout:)` promises. Using it would trade admitting too much for
killing what is already running.

Splitting the two halves is a core API decision (a `markDraining()`, or a
parameter on a published signature), and adding public surface to core on a
round's own authority is not this round's call. B-60.

## Canary

n/a — no fix. The load sweep from 402 is the control on the INSTRUMENT: the same
question with gaps reads noise, without gaps reads 337x.

## Gate

Not run: no library code changed. The round's artefacts are two probes, outside
analysis and the suite by design.

## Not fixed

B-60, with the measurement and the mechanism attached so whoever takes it starts
from the API question rather than from the bench.

## Links

- P-88 — repaired here, and now valid; 402 recorded it BROKEN with exactly this repair
- B-60 — the finding
- RPC-25 — the sibling's doc is what framed the question, and the sibling is what answered it
