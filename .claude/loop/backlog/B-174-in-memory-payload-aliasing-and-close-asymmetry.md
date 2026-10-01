---
status: open (round 575 did claim 1 of four)
round: 575
commit: e2d84db1
release: changelog
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/in_memory_transport.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
probe: P-196
reason: "cost — and the `cost` grading was WRONG for claim 1, which had a witness: the receiver read `0xFF 0xFF 0xFF 0xFF` where it was handed 0xAA. Claims 2, 3 and 4 remain, and those three are decided by reading"
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

### Claims 2, 3 and 4 remain

- **`send` after the peer cancelled reports success.** A comment asserting this is deliberate was
  written during round 575 and then REMOVED: nothing measured it, and rule one calls such a comment a
  lead rather than a closed door.
- **`close()` delivers our queued frames and drops the peer's.**
- **`RpcInMemoryTransport.pair` is `RpcChannelTransport.memoryPair`** under two public names.

Also unmeasured: whether any OTHER transport aliases a sent payload. The rule now sits on
`RpcTransportMessage`, which binds all of them, but only the direct channel was driven.

## Owner decision

—
