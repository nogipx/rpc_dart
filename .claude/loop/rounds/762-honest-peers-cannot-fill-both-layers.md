---
round: 762
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-04
bench: none — the honest arms cannot see the hostile case, and the raw-frame sender that could was not built
commit: yes
release: none
---

# Round 762 — honest peers cannot fill both layers

## Target

B-267, STALE and never measured: behind `RpcClientConnection`'s proxy the
responder budget does not share the transport's connection total, so "both
layers each hold up to the connection total". A measurement says who can
reach that. B-270 left open after round 760.

## Hypothesis

A peer streaming into a responder behind the proxy gets twice the connection
window buffered, against once without the proxy.

## Before

A victim `RpcPeerEndpoint` whose client-stream handler never reads, 1 MiB
connection window, 8 honest calls sending 64 KiB messages; messages counted
as the transport pulls them from the senders:

```
  direct (no proxy)   32 messages = 2048 KiB taken   all 8 calls parked (TIMEOUT)
  proxy               32 messages = 2048 KiB taken   all 8 calls parked (TIMEOUT)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/r762_proxy_hides_total.dart`

## Mechanism

Flow control parks an honest sender on credit before either layer reaches its
total, so the missing shared total never comes into play for it. A peer that
ignores credit would meet each layer's own refusal: 2x the window, bounded.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. The arms differ only in the proxy.
2. No: the two arms read the same, so this bench cannot show the doubling.
   It shows the honest case does not reach it, which narrows the lead; the
   hostile case needs a sender that ignores credit, not built here.
3. At the sender, as messages taken; the victim exposes neither layer's total.
4. Equal numbers, not zeros; the parked calls show flow control did act.
5. n/a.
6. n/a.
7. INCONCLUSIVE: what was tried is above and in B-267.
8. B-270 not re-taken; nothing dismissed.
9. None.
A1. One policy on both ends of the pair; the victim's is the one that counts.
A2. Volume.
L1. No refusal fired; the bound under test was never reached.

## Gate

n/a — no code change.

## Not fixed

B-267 stays open, reason narrowed to a flow-control-ignoring peer, bounded at
2x the window; the fix still needs a per-charge handle the interface lacks.

## Links

Lead `../backlog/B-267-the-reconnecting-proxy-hides-the-connection-total.md`.
Lens `../lenses/RPC-04-capability-hidden-by-wrapper.md` — `applied: [..., 762]`.
