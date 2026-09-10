---
round: 250
verdict: FIXED
packages: [rpc_dart]
lens: RPC-20
bench: none
commit: yes
---

# Round 250 — the ordering coincidence becomes an invariant

## Target

B-24, `decided by owner (round 247)` — an owner decision outranks anything the
round would pick for itself, and this is the one of the three that is
completable rather than blocked on measurement.

## Hypothesis

None to test. The defect class was established in round 240 and the exposure
here was established when B-24 was filed: `RpcFrameMultiplexedChannel` starts
decoding into `_incomingCtl` from its own constructor, and that controller was a
plain broadcast.

## Before

```
inbound controllers in the library                     7
buffered (BufferedBroadcastController)                 6
plain broadcast                                        1  <- this one
frames lost by it today                                0
```

Zero, because every construction goes through `RpcChannelTransport.fromChannel`,
which builds channel and transport in one expression with no await between.

## Mechanism

The safety is a property of a constructor's shape, not an invariant. Anything
that separates those two constructions — a `late final`, an async factory, a
validation step — reintroduces the loss with no test going red, and the type is
public and documented for direct construction, which is how the
`RpcWebSocketChannel.close()` deadlock became reachable.

## After

`_incomingCtl` is a `BufferedBroadcastController` with the transport's own
`sizeOf`, matching the other six. Round 245's fix applies to it for free:
metadata now counts against the byte bound here too.

## Canary

**None, and that is the decision rather than an oversight.** There is no witness
because no construction path in the library loses a frame today; a canary would
have to invent the very await whose absence makes the current code safe. The
owner authorised shipping on that basis (`B-24`, round 247), and the record says
so plainly instead of dressing a guard up as evidence.

What stands in its place: the whole core suite green under the change, which is
what would catch a regression in the buffering itself.

## Gate

`melos run analyze` SUCCESS (21 members + wasm) · `melos run test:unit
--no-select` SUCCESS · `melos run format:check` SUCCESS (after formatting the
edited file) · `melos run license:check` REUSE compliant. In the package:
analyze clean, `fvm dart test -j 8` 1420 passed / 1 skipped.

## Not fixed

The lead's other half is unchanged and unchanged deliberately: the constructor
ordering in `fromChannel` still matters for the FIRST bytes, because a buffering
carrier only helps at the hop it is on (RPC-20's own trap). This makes the hop
safe; it does not make every hop above it safe.

## Links

Lens RPC-20 — this is the shape it names, at the hop round 240 deferred ·
lead B-24, closed · the fix it inherits is round 245's · catalog U-11.
