---
round: 419
verdict: FIXED
packages: [rpc_dart_http2, rpc_dart_isolate]
lens: RPC-19
bench: none — both defects are a fact known at CONSTRUCTION that the code went
  somewhere destructive to rediscover, or never carried at all; the evidence is
  two ablations against named witnesses
commit: yes
---

# Round 419 — asking is not the same as destroying

## Target

**B-70's two behavioural items**, 23 and 34 — the ones the lead itself named as
worth taking first. The other 17 are duplication whose copies agree.

## Hypothesis

Two guards: check before the teardown, and carry the policy across.

Held for 23. For 34 there was nothing to carry it ON, which is why it was never
carried.

## Before

```
item 23   reconnect() on a viaSocket transport:
            _discardConnection, cancel every stream subscription, dispose
            every outgoing pump, clear six per-stream maps ...
            ... THEN call the factory, which is
                () => throw ...('does not support reconnect')

item 34   VM    : Isolate.spawn(..., [..., policy.toMap()])  -> fromMap
          web   : spawn(policy:) applies it to the HOST transport only;
                  runRpcIsolateManagerWorker takes
                  `RpcSecurityPolicy policy = const RpcSecurityPolicy()`
                  as a default parameter of the WORKER-side function
```

## Mechanism

**23: the only way to learn the answer was to make it true.** Whether a
`viaSocket` transport can rebuild its connection is fixed when it is
constructed — the caller handed us a socket we did not open. It said so by
passing a closure that throws, and `reconnect()` calls the factory LAST. So
every in-flight call died to produce an error that was known before the method
was entered.

**34: a `Worker` has no argument list.** The VM ships the policy as `args[4]`;
on web there was no equivalent, so the host ran at the caller's limits and the
worker at the stock ones, with no error anywhere. A raised
`maxMessageLengthBytes` held on one side of the boundary and not the other.

## After

`_connectionFactory` is **nullable, and null is checked BEFORE the teardown** —
the refusal is now free of side effects and the live connection survives it.
Null rather than a throwing closure is the point: a fact fixed at construction
is stored, not discovered by calling something.

The worker policy rides on the **worker URL**, which is the one channel a
`Worker` has at construction. `runRpcIsolateManagerWorker`'s `policy` becomes
nullable and OVERRIDES what the spawner sent; omitting it inherits.

## Canary

```
fix switched off                    witness failed with
the pre-teardown null check         "a refused reconnect leaves the connection
                                    working" AND "GUARD: a second refused
                                    reconnect also leaves it working" -- the
                                    call after the refusal fails, which is the
                                    defect stated exactly
withWorkerPolicy's carrier          "the policy survives the worker URL round
  (returns the uri unchanged)       trip" and "an existing query parameter ...
                                    survives"
```

The 23 canary failing its second GUARD as well as the witness is the reading
that matters: the connection is not merely degraded, it is gone, and asking
twice makes it worse.

## Where the hypothesis broke: an existing suite used the defect as a TOOL

`reconnect_failure_is_recoverable_test` went red on all four tests. Its helper
is documented as *"a transport whose reconnect factory ALWAYS throws, by
construction"* — it used `viaSocket` precisely BECAUSE the factory threw, to
isolate "the reconnect attempt failed" from "the connection died".

That suite measures something real and different from this round's subject: a
transport that CAN reconnect but whose attempt failed must stay open and
recoverable. **So the answer is a split, not a replacement** — `viaSocket` takes
an `@visibleForTesting connectionFactory`, the suite passes one that throws, and
both behaviours are now covered separately:

- no factory → refuse, destroy nothing (this round);
- a factory that fails → tear down, stay open, stay recoverable (that suite).

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

`rpc_dart_http2` gained a `meta` dependency for `@visibleForTesting`.

## Not fixed

**The worker-policy round trip is witnessed as a PAIR of pure functions, not end
to end.** `withWorkerPolicy` and `policyFromWorkerUrl` live outside the
`dart:js_interop` file specifically so anything could test them — the real round
trip crosses a `Worker` boundary that neither a VM test nor the web gate builds.
What is NOT covered is that `spawn()` actually calls the first and
`runRpcIsolateManagerWorker` actually calls the second; those are two one-line
call sites read by eye.

**A worker built before this change ignores the parameter**, since it is the
worker's own entrypoint that reads the URL. An old worker script keeps running
at stock limits, silently, exactly as before — there is no version handshake to
notice.

**17 of B-70's items remain**, all duplication whose copies currently agree.

## Links

- B-70 — items 23 and 34 closed; 17 remain
- RPC-19 — one flag, two lifecycle meanings: "cannot reconnect" and "the
  reconnect failed" were the same closure
- round 414 — `reconnect()` became load-bearing when the retry started calling
  it, which is what makes a destructive refusal worse than it was
