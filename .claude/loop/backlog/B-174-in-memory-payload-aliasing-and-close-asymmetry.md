---
status: closed (round 590)
round: 576
commit: b9a491c4
release: changelog
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/in_memory_transport.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
probe: P-197
reason: "all four claims answered. Claims 1-3 measured in 575-576; claim 4 decided by the owner in the round-590 review (deprecate `.pair`, keep `memoryPair`) and carried out as a 225-site sweep, because `--fatal-infos` makes every internal use of a deprecated member fatal"
---

# B-174 — in-memory: payloads are aliased and delivered later; close drops frames asymmetrically; two names for one factory

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_output.add(message)` passes the Uint8List by reference and delivers it a microtask later, so a sender reusing its buffer after `await sendMessage` corrupts what the receiver reads (only `directPayload` carries a warning); `send` after the peer cancelled reports success; `close()` delivers our queued frames and drops the peer's; `RpcInMemoryTransport.pair` is `RpcChannelTransport.memoryPair`.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart:45-54`;
`in_memory_transport.dart:22-26`; `core/transport.dart:29-32`.

## Why it matters

Silent data corruption for buffer-reusing senders; confusing API.

## Witness a round would build

Send, mutate the buffer, read on the receiver.

## Fix sketch

Document (or copy) payload ownership; pick one public name.

## Outcome (round 575) — claim 1 CONFIRMED, and the lead's own grading was wrong about it

`../rounds/575-the-bytes-the-sender-kept-writing-to.md`. Bench `P-196`.

```
WITNESS  the sender scribbles 0xFF over the body after the await
    the receiver read  0xFF 0xFF 0xFF 0xFF
CONTROL  the sender leaves it alone
    the receiver read  0xAA 0xAA 0xAA 0xAA
```

One variable, and the receiver's frame changes under it. **Filed as `cost`, "decided by reading" —
claim 1 is not**: it is a statement about bytes and it fires.

**The behaviour is unchanged and that is the fix.** The rule is now written where the API is,
`RpcTransportMessage.payload`, the mirror of what `IRpcChannel.incoming` states for a delivered chunk,
and `send`'s doc records the measurement. A test pins it, so the contract has the witness a doc
comment cannot have: adding a copy makes the witness read `0xAA` and the failure message says why that
is not a quiet improvement.

**The COPY is the owner's.** It would fix the corruption and cost a copy on the one transport whose
point is not copying — `B-116` priced one such copy at `389.76 -> 191.45 us` per 1 MiB on the receive
path, and that trade was settled there by writing the contract rather than paying it. The standing
requirement is to ask before trading speed.

### Claims 2 and 3 (round 576) — both CONFIRMED; one pinned, one unfixable at an acceptable price

`../rounds/576-the-fix-that-cost-more-than-the-defect.md`. Bench `P-197`.

```
CLAIM 3  the CLIENT closes     client [] / server [from-client]
         the SERVER closes     client [from-server] / server []
CLAIM 2  send after the peer closed
         the send  returned normally / the peer received [] / our isClosed TRUE
```

Claim 3 is symmetric: the CLOSING side loses, not a role. Claim 2 is sharper than filed — `isClosed` is
already true, so it is not about an unreachable peer but about a send on a channel that knows it is
closed.

**Claim 3 is NOT fixed and the price is measured.** A one-turn yield before the cancel does deliver the
peer's frame — round 573's shape — but the turn lands inside the close CASCADE either side of
`_output.close()`, so the peer's `onDone`, its channel and its transport all shift a turn later, and
`in_memory_transport_test`'s named requirement *"a send with nowhere to go is refused, not reported
sent"* fails: the peer's `sendMessage` right after `await close()` stops throwing and succeeds
silently. That is the worse of the two losses and the class rounds 558, 568 and 571 each fixed. Both
orderings were tried. **What a future round needs is a way to drain the subscription without putting a
turn in the cascade**, which `dart:async` does not offer on a `StreamSubscription`.

**Claim 2 is pinned.** 2 of 2 implementations do `if (_closed) return`, `RpcChannelTransport` throws
`RpcClosedException` for callers who go through it, and changing the channel's error path touches every
direct user. Both rules are now on `IRpcMultiplexedChannel`, which said nothing about either, with a
test each.

### Claim 4 is the owner's

**`RpcInMemoryTransport.pair` is `RpcChannelTransport.memoryPair`** under two public names. Picking one
is a breaking rename, which is the owner's by precedent — and the lead carries `awaiting owner` for that
alone, so no round can quietly rename public API on its way past.

The question, with its options, for the review:

1. **Keep both and document one as the preferred spelling.** Nothing breaks; the duplication stays in
   the public surface and in every example a reader copies from.
2. **Deprecate `RpcInMemoryTransport.pair`** in favour of `RpcChannelTransport.memoryPair`, which is
   where the implementation lives. A deprecation is visible to every caller at analysis time and the
   removal is a later major.
3. **Deprecate the other way**, keeping the shorter name as the public one and making
   `memoryPair` internal. More churn, and `RpcChannelTransport` is where the type actually is.

My judgement, not a measurement: option 2, because the name that survives should be the one whose class
owns the code. What I cannot see from here is how much published example and user code spells it the
other way.

Also unmeasured: whether any OTHER transport aliases a sent payload. The rule now sits on
`RpcTransportMessage`, which binds all of them, but only the direct channel was driven.

## Owner decision

**Option 2, round 590: deprecate `RpcInMemoryTransport.pair` in favour of
`RpcChannelTransport.memoryPair`.** The surviving name is the one whose class owns the
implementation; removal is a later major.

Cost reported to the owner before carrying it out, because it is not the one-line
annotation the question implied: `melos run analyze` runs `--fatal-infos`, so every
internal use of a deprecated member is fatal, and there are **201 call sites in 80
Dart files across 9 packages** plus the docs. The annotation and the migration are one
change or the gate is red.
