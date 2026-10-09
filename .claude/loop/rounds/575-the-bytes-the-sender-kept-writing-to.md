---
round: 575
verdict: FIXED
packages: [rpc_dart]
lens: RPC-10
bench: P-196 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S3
---

# Round 575 — the bytes the sender kept writing to

## Target

`B-174`'s first claim, taken because the file was already open from round 574 and because "silent data
corruption" is the one damage class a later round cannot undo. The lead is filed `cost` — "decided by
reading" — and that grading is what this round disputes: claim 1 has a witness and it fires.

Scope stated up front: **claim 1 of four.** Claims 2 (`send` after the peer cancelled reports
success), 3 (`close()` delivers our queued frames and drops the peer's) and 4 (`RpcInMemoryTransport.pair`
is `RpcChannelTransport.memoryPair` under two names) are untouched and stay on the lead.

Lens RPC-10: a shared layer's blast radius — this contract is `RpcTransportMessage`'s, so it binds
every transport rather than this channel alone.

## Hypothesis

The direct channel passes `payload` by reference and delivers it a microtask later, so a sender
reusing its buffer after `await sendMessage` rewrites what the receiver reads.

## Before

```
WITNESS  the sender scribbles 0xFF over the body after the await
    the receiver read  0xFF 0xFF 0xFF 0xFF

CONTROL  the sender leaves it alone
    the receiver read  0xAA 0xAA 0xAA 0xAA
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b174_payload_aliasing.dart`. One variable — whether
the sender touches the buffer after the await — and the receiver's frame changes under it.

## Mechanism

`send` hands the message object straight to the output controller, so the receiver holds the sender's
own list, and delivery is a microtask later. That is what being zero-copy IS; the defect is that
nothing said so. `directPayload` carries "must be immutable or cloned"; `payload` carried nothing.

## After

The behaviour is unchanged and that is the fix. The rule is now written where the API is —
`RpcTransportMessage.payload`, the mirror of what `IRpcChannel.incoming` already states for a
delivered chunk — and `send`'s own doc records the measurement.

**A copy on send is NOT taken, and that is deliberate.** It would make the witness read `0xAA`, and it
is a speed trade on the one transport whose point is not copying — `B-116` measured a single such copy
at `389.76 -> 191.45 us` per 1 MiB frame on the receive path, and the owner settled that trade by
writing the contract rather than paying it. The standing requirement is to ask before trading speed,
so the copy is the owner's and is named on the lead.

## Canary

A documentation fix has no witness, so the contract got one: a test that pins the measured ownership
and fails if the copy is ever added quietly.

```
copy on send added (`payload: p.sublist(0)`)

  a sent payload belongs to the receiver, not the sender
    Expected: [255, 255, 255, 255]
      Actual: [170, 170, 170, 170]
    the zero-copy channel delivers the same list the sender passed; if this now
    reads 0xAA someone added a copy on send, which is a speed trade on the one
    transport whose point is not copying -- see the ownership rule on
    RpcTransportMessage.payload

  CONTROL passes
```

That is the inverse of the usual canary and it is the honest one here: the thing that must not change
silently is the contract, so the arm that fails is the one that changes it.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart +1873 ~1
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2189 / 2189, REUSE compliant
```

## Not fixed

**Three of the lead's four claims.** Named rather than left implicit: `send` after the peer cancelled
returning normally (claim 2) — a comment asserting that this is deliberate was written in this round
and then REMOVED, because nothing here measured it and rule one calls that a lead rather than a closed
door; `close()` delivering our queued frames and dropping the peer's (claim 3); and the two public
names for one factory (claim 4).

**Whether any other transport aliases a sent payload is unmeasured.** The rule is written on
`RpcTransportMessage`, which binds all of them, but only the direct channel was driven. A transport
that serializes cannot have the defect; one that queues the list could.

**The receive-side mirror was not re-read.** `IRpcChannel.incoming`'s rule is cited from `B-116`'s
record rather than from the code.

## Links

Lead `../backlog/B-174-in-memory-payload-aliasing-and-close-asymmetry.md` — claim 1 CLOSED, three
claims open, so the lead stays open.
Lead `../backlog/B-116-every-inbound-message-is-copied-three-times.md` — the same trade settled in the
other direction, and the number that makes a copy here the owner's call.
Bench `../probes/P-196-who-owns-a-sent-payload.md` — new.
Lens `../lenses/RPC-10-shared-layer-blast-radius.md` — `applied: [575]`.
Lesson: none. What this round applied is the standing requirement to ask before trading speed, and
`canary.md`'s rule that a fix needs a failing arm — met here by inverting which side of the contract
the arm sits on.
