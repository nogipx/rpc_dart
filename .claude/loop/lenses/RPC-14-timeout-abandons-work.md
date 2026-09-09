---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: there are timeouts around operations that hold a resource
breaks: "unbounded growth: the held resource is never released. On this project the price is a leaked isolate rather than a socket: it holds ports and keeps the process from exiting."
applied: [223, 233, 246]
status: swept here (round 246, cd6ee68e)
---

# RPC-14 — A timeout abandons the wait, not the work

## Shape

`Future.timeout` around an operation that holds a resource: the waiter is
released, the operation keeps holding.

## Detector

Grep `.timeout(` and, for each hit, ask: **if this fires LATE and succeeds
anyway, who owns what it produced?** Harmless when the value is data — a ping
reply, a response body. A leak when it is a handle: a socket, an isolate, a
subscription, a file handle.

**The fix, since a `Future` cannot be cancelled, is to ADOPT the abandoned one**
— `pending.then((r) => r.close()).catchError((_) {})` inside `onTimeout`. A
source that then fails late, or never settles at all, costs nothing.

## Ask

What lives on after the timeout fires, and who releases it?

## The wider family — an await another path can interleave with

Imported from private memory after round 239. The timeout is one member; the
shape is "the loser of a race holds a resource nobody owns", and **fixing one
interleaving is not evidence the other is safe** — both callers had the
close-during-reconnect half fixed long before anyone asked about
reconnect-during-reconnect.

    RpcClientConnection connectTimeout   334b3337   the abandoned factory result
    close() DURING reconnect, both       -          re-check after the await and
      callers                                       close what would be abandoned
    reconnect() during reconnect,        473789b9   each attempt opened a
      websocket and http2                75fd517f   connection and the last
                                                    assignment won: ONE ORPHAN
                                                    PER EXTRA ATTEMPT (2 -> 1,
                                                    3 -> 2). Fixed by
                                                    SINGLE-FLIGHT, a second
                                                    caller joining the first

**The family is swept — do not re-hunt it** (round 67). `RpcClientConnection`
measured clean: `_connectingGuard` refuses a second loop and the loop completes
it synchronously after attach, so no window exists — 4x concurrent
`forceReconnect`, a drop racing `forceReconnect`, and repeated drops all gave
`created == closed`, orphans 0. Pinned by
`test/resilience/client_connection_concurrency_test.dart`, because the behaviour
was correct but untested and `_onTransportDropped` nulls the guard deliberately.
`RpcChannelTransport.reconnect()` is documented unsupported and acquires no
resource, so isolate and wasm have nothing to race.

> **The load-bearing guards for a single-flight fix**, both easy to omit: a LATER
> reconnect must still open a new connection (the in-flight marker has to clear),
> and the transport must still SERVE a call afterwards.

## Evidence

Swept across core off-journal at round 067. The isolate package was NOT part of
that sweep — the exception was carried as lead B-04 — and round 223 swept it,
clean. All four sites:

```
.timeout( in rpc_dart_isolate/lib                    4 sites

  isolate_transport.dart:419  first handshake     catch -> teardownStartup()
                                                  kills the isolate, cancels
                                                  all three subscriptions,
                                                  closes all three ports
  isolate_transport.dart:571  ready ack           catch -> hostTransport.close()
                                                  then teardownStartup()
  isolate_transport_web.dart:316 initialization   catch -> abandon()
                                                  closes the transport and
                                                  terminates the worker
  isolate_transport_web.dart:385 ready grace      onTimeout: () {} — DELIBERATE
```

Round 223's verdict was reached by MEASURING, not reading: four spawns against a
synchronously blocking entrypoint all raised `TimeoutException`, none of the
workers reached their post-block marker — so every isolate really was killed,
even mid-busy-loop — and the process exited promptly afterwards.

> **Do not add a watchdog `Timer` to detect "the process is still alive".** A
> pending Timer keeps the event loop alive by itself, so the check reports a hang
> unconditionally. Let the process exit BE the observable and time the run.

The fourth site is the one worth knowing about. Its empty `onTimeout` looks
exactly like this lens's defect and is not: a worker built before the ready
protocol never sends the ack, and hanging those would be a worse regression than
the wait, so proceeding without it is the point. `readySub.cancel()` runs on both
paths, and a post-timeout error from the abandoned `Future.any` is swallowed by
`timeout`'s own handler rather than reaching the root zone. U-01 applies: the
comment justifying it was treated as a lead and checked against the code, not
taken as a closed door.

Round 233 pointed the same detector at `rpc_dart_websocket`, which is NOT in
this lens's paths and never has been:

```
  .timeout( | Timer( | Timer. | Completer   whole package    0 hits
```

**Absent, not guarded** — a stronger result than a clean sweep, and the reason
the paths above still do not list websocket: adding it would claim a sweep where
there was nothing to sweep. The control is round 223's identical grep, which
returned four sites in `rpc_dart_isolate`.

## What the sweep does NOT establish

Every site is guarded, and **no test would notice if a guard were removed.**
With `teardownStartup()` deleted from the failed-handshake path, so a stuck
isolate and its ports are left behind, the isolate suite still passes (`+73`).
So this verdict is "the class does not arise today", not "the class cannot
arise". See `../lessons/L-04-a-guard-with-no-witness.md`; the witness needs the
subprocess shape `close_releases_the_isolate_test.dart` already uses.
