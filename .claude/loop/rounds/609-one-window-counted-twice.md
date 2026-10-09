---
round: 609
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-25
bench: P-211 — reused
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 609 — one window counted twice

## Target

B-225 item 1: the transport ledger and the pipeline budget each cap un-consumed
request bytes at the connection window, and count separately. Round 595 measured
each layer alone; nothing measured a peer that fills both.

## Hypothesis

A peer mixing bidi streams (transport ledger) and client-streams (pipeline budget)
on one connection holds the window once per layer — twice the bound.

## Before

```
8 streams, 4 bidi + 4 client-stream, peer ignores the window
connection window 128 KiB, 1 KiB messages, ceiling 128
retained                                  252
```

The new `mixed` arm of `the_connection_total_is_bounded_test.dart`.

## Control

The single-layer arms of the same file, 8 client-streams and 8 bidi streams, each
stay at or under 128, and the honest-peer arm is never refused.

## Mechanism

`RpcResponderBufferBudget.admits` compared `heldBytes` with the window, and
`RpcStreamBufferLedger.admit` compared `_total` with the window. Neither saw the
other's count.

## After

```
retained                                  126
```

New optional capability `IRpcConnectionBufferTotal`
(`chargeConnectionBuffer` / `releaseConnectionBuffer`). `RpcChannelTransport`
implements it over its ledger's total. The pipeline's budget charges it in place of
its own ceiling when the transport offers it, through `take` / `give`, which
replace the separate admit-then-add. `RpcWebSocketResponderTransport` forwards it.
The websocket caller wrapper does not, because it replaces `_inner` on reconnect
and a cached budget would release into the wrong ledger. Without the capability
the budget keeps its own ceiling, the old behaviour.

## Canary

`shared:` forced to null in `_respBudget`: the `mixed` arm fails, `Expected: a
value less than or equal to <128>, Actual: <252>`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (rpc_dart +1911,
websocket +250, http2 +275), `melos run format:check`, `melos run license:check`
— green.

## Not fixed

B-225 items 2 (zero-copy weighs 0 bytes) and 3 (the pause contract on the other
channels). The lead stays open for them.

## Links

Lead `../backlog/B-225-what-the-connection-total-does-not-see.md` — narrowed.
Bench `../probes/P-211-a-flood-into-a-stalled-handler.md` — reused, round-609 section.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 609]`.
Test `packages/core/rpc_dart/test/transports/the_connection_total_is_bounded_test.dart`.
