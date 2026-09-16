---
round: 367
commit: b17af71c
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
scope: [rpc_dart, rpc_dart_http2]
---

# C-39 — extracting the flow-control duplication earns nothing

Asked of the three copies of flow-control accounting — `RpcChannelTransport`
(credit and grants), and the two http2 transports (un-consumed budget, refuse
past it) — whether they have drifted, and whether any of them is unwatched.
Either would make an extraction a repair. Neither holds.

**Drift.** The two http2 copies differ in four places, and all four are
specialisations reachable only on their own side: the `_fcOnDelivered` gate
(the responder also admits `_fcDeferred`; the caller has no defer path), the
refusal action (trailer plus synthesized cancel, against stream error plus
RST_STREAM), and the `_fcForget` call sites (the caller also forgets at
end-of-stream, where the response is complete; on the responder the same frame
is a half-close and the call continues).

The fourth is genuine drift with no justification: **three copies, three answers
to what `close()` clears.**

    responder close()   _fcDeferred, _fcOutstanding   not _fcRefused
    caller close()      neither
    core close()        all of them

Not a defect. After `close()` every write is refused by the transport's own
`isClosed` guard, the maps die with the object, and a reconnect builds a new
transport rather than reusing this one, so nothing reads the difference.

**Coverage**, the round-331 criterion — the same rule ablated in each copy,
against each package's own suite:

```
copy                              baseline      ablated
http2 responder _fcOnDelivered    +218          +212 -6
http2 caller    _fcOnDelivered    +218          +217 -1
core _fcTryConsume                +1485 ~1      +1484 ~1 -1
```

No copy is at zero. Round 331's bar is one watched and one NOT; 6/1/1 is unequal
in degree only, so an extraction would inherit coverage the copies already have.

Separately: `RpcFlowController` — extracting the credit scheme out of
`RpcChannelTransport` — is not an RPC-25 candidate at all. There is ONE copy of
that mechanism; the lens needs siblings and has none.

## Control

Each arm is its own control: the ablation removes exactly one rule and the same
suite runs either side of it. All three went red where the baseline was green
(`+218` → `+212 -6`, `+217 -1`; `+1485 ~1` → `+1484 ~1 -1`), so the instrument
demonstrably sees this class of defect and a "clean" reading is not the bench
failing to reach the regime.

Two of the three failed with a real message and a number — *8.6 MiB reached the
server for a handler consuming nothing*, *handler produced 20639 more items
(80.6 MiB) while the client was paused*. The core's failed by 30-second timeout,
which is the weak form; recorded in round 367 under "Not fixed" rather than
repaired here.

The tree was restored between arms and `git diff --stat` verified empty before
the verdict.
