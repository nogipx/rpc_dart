---
round: 715
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2, rpc_dart_http]
lens: RPC-17
bench: none — `.dart_tool/probe/audit_h2/depth.dart`, `bidi.dart`
commit: yes
release: changelog
---

# Round 715 — h2 uploads bounded by bytes

## Target

B-261, by the owner's decision: bytes only on h2. B-262 and B-265 closed by
documentation, also the owner's decisions.

## Hypothesis

The responder's depth bound applies on h2, where nothing tells the sender the
depth, so a client stream of small messages to a handler with any per-message
latency fails although it is far below the byte bound h2 already enforces.

## Before

```
30000 x 8 bytes, handler pauses 1 ms every 20:
upload FAILED after consumed=8272: RESOURCE_EXHAUSTED (max: 8192 messages)
bidi FAILED: RESOURCE_EXHAUSTED
fast handler (control): 30000/30000
```

## Mechanism

As hypothesised.

## Fix

A marker in core, `IRpcNoMessageCredit`: the responder pipeline sizes the
request budget's depth at 2^30 for a transport declaring it. Negative polarity
on purpose: a transport or decorator that says nothing keeps the depth, so
round 550's bound on direct objects survives every wrapper that forgets it.
The h2 responder declares it, and so does the server's capability-preserving
wrapper.

Docs: the policy and the skill state that with only the connection window on
there is no message credit (B-262); the rpc_dart_http README states that a
cancel stays on the caller's side and every streaming call needs a deadline
(B-265).

## After

```
upload OK: done 30000 consumed=30000
bidi OK: (done 30000)
```

## Canary

The marker removed from both h2 classes: the new witness fails with
"max: 8192 messages".

## The verdict questions

1. Yes. 2. Yes. 3. Yes. 4. Not zero. 5. Quoted. 6. One cause. 7. The owner's
trade: h2 request queues are no longer bounded by depth; the 4 MiB byte bound
stays. 8. None.

## Gate

`analyze`, `format:check`, `check:skills`, `test:unit` (one run failed in
three packages under load; each failing file passed alone and a rerun of the
whole gate was green), rpc_dart_http2 suite 300.

## Not fixed

B-266, the six minor audit items.

## Links

Leads `../backlog/B-261-h2-uploads-meet-the-depth-without-credit.md`,
`../backlog/B-262-the-connection-window-alone-has-no-message-credit.md`,
`../backlog/B-265-an-h1-client-cancel-never-reaches-the-server.md` closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` -- `applied: [..., 715]`.
