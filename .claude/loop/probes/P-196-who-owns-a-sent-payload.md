---
file: packages/core/rpc_dart/.dart_tool/probe/b174_payload_aliasing.dart
round: 575
commit: e2d84db1
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
status: valid
---

# P-196 — who owns a sent payload?

## Why it exists

B-174 is filed `cost`, "decided by reading". Its first claim is not: "a sender reusing its buffer
after `await sendMessage` corrupts what the receiver reads" is a statement about bytes, and the lead
names the arm — send, mutate, read on the receiver.

## The harness

A `memoryPair`, a frame built by hand so both halves are known (the 5-byte gRPC prefix, then four
bytes of 0xAA), and one variable: whether the sender scribbles 0xFF over the body immediately after
`await sendMessage` returns. The receiver's handler records what it was given.

Built by hand rather than through a codec because the point is the exact bytes: a serialized object
would make the body whatever the codec produced and the scribble would land somewhere unknown.

## The numbers (round 575)

```
WITNESS  the sender scribbles 0xFF after the await
    the receiver read  0xFF 0xFF 0xFF 0xFF

CONTROL  the sender leaves it alone
    the receiver read  0xAA 0xAA 0xAA 0xAA
```

Unchanged after the round: the behaviour IS the contract, and what the round added is the rule
written down plus a test that fails if a copy is ever added quietly.

## Measures

The bytes the receiver's handler was handed, as bytes. Nothing derived — a length or a checksum would
have hidden which end the corruption came from.

## Control

**The same send with the mutation removed.** It reads 0xAA, so the witness's 0xFF is the sender's own
write arriving through the channel rather than the channel mangling a payload.

## What it establishes, and what it does not

Establishes that the zero-copy channel delivers the sender's own list, so a sender that reuses the
buffer writes into the receiver's frame — silent, since nothing throws and the length is right.

Does NOT establish that a copy on send is wrong. It would fix the corruption and cost a copy on the
one transport whose point is not copying; `B-116` priced one such copy at `389.76 -> 191.45 us` per
1 MiB, which is why that is the owner's call and not this probe's.

Does NOT cover the other three claims on the lead — send-after-cancel, the asymmetric close, or the
duplicate factory name.

Does NOT check any other transport. The rule now written on `RpcTransportMessage.payload` binds all of
them; only this channel was driven, and one that serializes cannot have the defect.
