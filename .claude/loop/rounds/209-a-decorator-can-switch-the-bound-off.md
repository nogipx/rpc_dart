---
round: 209
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-04
bench: P-03 — new
budget: probes 0/3, canaries 1/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and the canary; approved 10 of 10
commit: yes
---

# Round 209 — a decorator that declares a capability can switch the bound off

## Target

Not the lens `next` named. RPC-01 has driven three rounds running (206, 207,
208) purely because its status is `confirmed` rather than `swept here`, and
SKILL.md ranks a lens NEVER APPLIED above the rank. RPC-04 (`applied: []`) is
that lens, and round 208 had just made a second capability — `IRpcFlowControlled`
— load-bearing for a brand-new bound, so it is also the natural place to attack
the previous round's own fix (U-02).

## Hypothesis

The detector is "grep both type checks; for every transport package walk the
wrapper chain from construction to the check site". The chain only exists where
a wrapper hook does, so: does the round-208 budget survive
`RpcHttp2Server.transportWrapper`?

## Before

```
A deaf client-stream handler, a 4 MiB flowControlWindowBytes, bytes counted
on the WIRE by a raw TCP relay:

  no wrapper                        4176 KiB
  plain decorator                   4177 KiB
  declares and forwards it          4177 KiB
  declares and SWALLOWS it        160900 KiB   <- 39x, still climbing at 8 s
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/wrapper_keeps_the_bound.dart`
(P-03).

The first three rows are the control set, and they matter as much as the fourth:
they say round 208's fix is intact for every ordinary decorator, so the fourth
row is about the capability and not about wrapping as such.

## Mechanism

The sweep first: `transportWrapper` exists ONLY on `RpcHttp2Server`. The
websocket and http servers have no wrapper hook, isolate hands back a
`RpcChannelTransport` directly, and the websocket wrappers forward both
interfaces — so http2 is the whole surface, and `_preserveCapabilities` already
covers `IRpcSecurityPolicyAware`.

What it does not cover is that a wrapper can only ever report CONSUMPTION. The
charge lives in the transport that sees bytes arrive, and since round 208 that
transport only charges a stream it has been told is pipeline-fed
(`_fcDeferred`, the guard that stops a large unary request refusing itself). But
`_CapabilityPreservingTransport._flowControlled` PREFERS the wrapper, so a
decorator declaring `IRpcFlowControlled` and swallowing it means the inner
transport is never told — and never charges. The bound is not loosened, it is
absent.

The comment on `_flowControlled` blesses exactly that shape ("a decorator that
meters flow control keeps control of it"), which is what made it invisible.

## After

```
  no wrapper                        4177 KiB
  plain decorator                   4176 KiB
  declares and forwards it          4176 KiB
  declares and SWALLOWS it          4187 KiB
```

`deferFlowCredit` now also goes to the inner transport, always. That is a set
membership, so a forwarding decorator still produces one entry rather than two.

`returnFlowCredit` is deliberately NOT doubled the same way: a forwarding
decorator would then discharge twice and the bound would vanish again, the other
way round. The `forwards` row above is what guards that — it stays at 4176 KiB.

A decorator that swallows the report now STARVES the budget rather than removing
it, so its calls are refused at the window instead of running unbounded. That is
the loud failure, which is the one to have.

## Canary

`deferFlowCredit` on the inner transport removed (`if (1 > 0) return;`), against
the four new cases in `transport_wrapper_capabilities_test.dart`:

    Expected: a value less than <8388608>
      Actual: <164764189>
    157.1 MiB reached a server whose handler consumed nothing, against a
    4 MiB window

Only the `swallows` case failed. `none`, `plain`, `forwards` and the four
pre-existing capability tests all stayed green, which is what shows the witness
isolates this defect rather than re-checking the round-208 one.

## Gate

`melos run analyze` green; `melos run format:check` green;
`melos run test:unit --no-select` green across the workspace.

## Not fixed

Nothing in scope. The doc comment's promise that a decorator "keeps control" of
flow control is now narrower than it reads — it keeps control of the REPORTING,
never of whether the accounting happens — and the code says so where it is
routed. Whether the extension point should let an application opt out of the
bound entirely is a design question, not a defect; nobody has asked for it.

## Links

Lens `../lenses/RPC-04-capability-hidden-by-wrapper.md` — `applied: [209]`,
status refreshed, and its prose corrected: it claimed round 205 filed the
websocket/isolate check in `checked/`, and no such negative exists.
Bench `../probes/P-03-wrapper-keeps-the-bound.md` — new, validated by its
control set.
Round `208-refuse-instead-of-pausing.md` — the bound this protects.
