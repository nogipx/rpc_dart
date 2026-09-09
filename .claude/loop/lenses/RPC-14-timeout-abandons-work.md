---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: there are timeouts around operations that hold a resource
breaks: "unbounded growth: the held resource is never released. On this project the price is a leaked isolate rather than a socket: it holds ports and keeps the process from exiting."
applied: [223]
status: swept here (round 223, 0e7b984a)
---

# RPC-14 — A timeout abandons the wait, not the work

## Shape

`Future.timeout` around an operation that holds a resource: the waiter is
released, the operation keeps holding.

## Detector

Grep `.timeout(` and match each hit against what the operation underneath holds.

## Ask

What lives on after the timeout fires, and who releases it?

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

The fourth site is the one worth knowing about. Its empty `onTimeout` looks
exactly like this lens's defect and is not: a worker built before the ready
protocol never sends the ack, and hanging those would be a worse regression than
the wait, so proceeding without it is the point. `readySub.cancel()` runs on both
paths, and a post-timeout error from the abandoned `Future.any` is swallowed by
`timeout`'s own handler rather than reaching the root zone. U-01 applies: the
comment justifying it was treated as a lead and checked against the code, not
taken as a closed door.

## What the sweep does NOT establish

Every site is guarded, and **no test would notice if a guard were removed.**
With `teardownStartup()` deleted from the failed-handshake path, so a stuck
isolate and its ports are left behind, the isolate suite still passes (`+73`).
So this verdict is "the class does not arise today", not "the class cannot
arise". See `../lessons/L-04-a-guard-with-no-witness.md`; the witness needs the
subprocess shape `close_releases_the_isolate_test.dart` already uses.
