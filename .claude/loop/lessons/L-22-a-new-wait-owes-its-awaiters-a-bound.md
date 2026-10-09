---
round: 751
class: process
cost: one regression shipped by round 750 and found the round after; a call with a 1 s deadline returned after 5.1 s
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
commit: 4c32a82b
status: active
---

# L-22 — a new wait owes its awaiters a bound

## The rule

A change that makes an operation wait, where it used to answer at once, owes
every caller that awaits it a check: does the caller bound the wait by its
own deadline and cancellation? The callers were written against an operation
that never blocked, so none of them had a reason to.

## What it cost

Round 750 made the proxy's `reconnect()` wait up to 5 s for the connection's
next attempt, and bounded that wait by its own 5 s limit. Its only caller,
`RpcRetryInterceptor`, awaited `reconnect()` bare. A call with a 1 s deadline
returned after 5.1 s, and a cancelled one after 5.1 s too. Round 750's review
checked the new wait's own limit, not its caller.

## How to apply

When a fix adds an `await` that can take time, run `find_callers` on the
method and read each caller's await: a deadline, a token, or a reason it
needs neither.
