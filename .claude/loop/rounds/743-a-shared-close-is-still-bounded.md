---
round: 743
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: P-247 — new
commit: yes
release: none
---

# Round 743 — a shared close is still bounded

## Target

`loop.py next` lists RPC-09 as swept, with 8 files changed since its sweep at
472dd6af. All 8 are changes from rounds 729–732. The riskiest is round 732:
concurrent `close()` calls now share one future. Before it, a second close
returned at once, so a hung first close could not trap the second. RPC-09's
breakage is "a hang that never ends", and sharing the future spreads one.

## Hypothesis

Something in `_closeResources()` is unbounded. It runs before the 5 s
transport-close timeout. A stuck handler then hangs both closes for ever.

## Before

Every await under `_closeResources()`, read from the code:

```
caller   closeCallerResources       cancel of the transport's incoming sub
responder closeResponderResources   cancel of the incoming sub, then
                                    _cleanupStream per stream:
                                      responder.close()  pumps not awaited,
                                                         controller cancels
                                      RpcCallScope.close disposers BOUNDED by
                                                         disposerTimeout
```

The only await that runs user code is the call-scope disposer, and it is
bounded. P-247 measures it with two concurrent closes over all four shapes:

```
                     disposerTimeout   close#1        close#2
healthy handlers     400 ms            10 ms          10 ms
stuck handlers       400 ms            404 ms         404 ms
stuck handlers       1 h (ablation)    HUNG at 15 s   HUNG at 15 s
```

## Mechanism

None. Closing cancels every call's token before the per-stream cleanup, so
the four scopes start closing at once. Their disposers time out together,
in 404 ms rather than 4 × 400.

## After

n/a.

## Canary

n/a — no fix. The ablation is the control: without the disposer bound both
closes hang, so the probe can see a hang and the bound is what prevents it.

## The verdict questions

1. n/a: no fix.
2. Yes: the ablation hangs both closes, and the healthy arm returns in 10 ms.
3. At the caller of `close()`.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. The default policy; disposerTimeout lowered to 400 ms to keep the run short.
A2. Latency of each close.
L1. 404 ms is the 400 ms bound plus one turn.

## Gate

No library change.

## Not fixed

A custom `IRpcTransport` whose `incomingMessages` cancel never completes
would still hang `close()` before the transport timeout. It did before round
732 as well, for the first close. The shipped transports cannot, read from
the code rather than driven: each `incomingMessages` is a controller's
stream (channel, http2 caller and responder, http caller and responder,
websocket caller, the reconnecting proxy's `BufferedBroadcastController`), or
it delegates to one (http2 server wrapper, websocket responder). None of those
controllers sets an asynchronous `onCancel`. The only one in the list,
`channel_transport.dart:334`, is synchronous.

## Links

Lens `../lenses/RPC-09-deadline-below-write.md` — `applied: [..., 743]`.
New bench `../probes/P-247-two-closes-on-a-stuck-handler.md`.
