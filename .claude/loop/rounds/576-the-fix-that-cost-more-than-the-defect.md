---
round: 576
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: P-197 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
severity: S3
---

# Round 576 — the fix that cost more than the defect

## Target

The two in-memory channel claims round 575 left behind: a send after the peer is gone reporting
success, and `close()` dropping the peer's queued frames while delivering ours. Both were open when
this round took them; the lead they belong to is named in `## Links`, for the reason round 549 records.

Scope: two claims, not the lead. Its fourth — one factory under two public names — is a breaking
rename, so it became the owner's as a RESULT of this round rather than something this round could
decide. That is in `## Not fixed`.

Lens RPC-21: drive the lifecycle twice — here close from each side.

## Hypothesis

`send` after the peer is gone reports success, and `close()` delivers our queued frames while dropping
the peer's.

## Before

```
CLAIM 3  the CLIENT closes, both ends had queued a frame
    the client received  []
    the server received  [from-client]

CLAIM 3  the SERVER closes, mirrored
    the client received  [from-server]
    the server received  []

CLAIM 2  send after the peer has closed
    the send           returned normally
    the peer received  []
    our isClosed       true
```

Both confirmed. Claim 3 is symmetric — it is the CLOSING side that loses, not a role. Claim 2 is
sharper than filed: `our isClosed true`, so this is not about the peer being unreachable but about a
send on a channel that knows it is closed. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b174_close_asymmetry.dart`.

## Mechanism

`close()` cancels the inbound subscription before closing the outbound controller, so queued inbound
events are discarded while queued outbound ones still flow. `send` starts with `if (_closed) return` —
and so does `RpcFrameMultiplexedChannel`'s, 2 of 2.

## After

Both rules are now stated on `IRpcMultiplexedChannel`, which had nothing to say about either, and both
have a test.

**Claim 3 is NOT fixed, and the reason is measured rather than argued.** One event-loop turn before the
cancel does deliver the peer's frame — the shape round 573 used for its 503. But the turn lands inside
the close CASCADE whichever side of `_output.close()` it goes, so the peer's `onDone`, its channel's
close and its transport's all shift a turn later. `in_memory_transport_test`'s
`a send with nowhere to go is refused, not reported sent` then fails: the peer's `sendMessage` right
after `await close()` stops throwing and succeeds silently. **Of the two losses that is the worse one**,
and it is the class rounds 558, 568 and 571 each fixed.

So the asymmetry is the price of a prompt close cascade, and the round records the tension instead of
trading one silent loss for another.

## Canary

```
A. the yield restored before `_sub.cancel()`
     close drops what the peer queued ...
       Expected: empty
         Actual: ['from-server']
     (and mirrored)

B. the same yield, with `_output.close()` moved ahead of it
     in_memory_transport_test: stops receiving messages after close
       Expected: throws <Instance of 'RpcStatusException'>
         Actual: <Instance of 'Future<void>'>
       a send with nowhere to go is refused, not reported sent
```

**B is the round's real result.** A is the ordinary ablation of the documented behaviour; B is the
attempted FIX failing an existing requirement by name, which is what settles the question. Both
orderings of the turn were tried.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart +1876 ~1
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2192 / 2192, REUSE compliant
```

## Not fixed

**Claim 3's asymmetry**, as above, with the number that forbids the obvious fix. A reader wanting to
revisit it needs a way to deliver queued inbound WITHOUT putting a turn in the cascade — a drain of the
subscription rather than a yield, which `dart:async` does not offer on a `StreamSubscription`.

**Claim 2 is pinned, not changed.** Making `send` throw on a closed channel would be the round-558 rule
applied one layer down, but 2 of 2 implementations agree on the silence, `RpcChannelTransport` already
throws `RpcClosedException` for callers who go through it, and changing the channel's error path
touches every direct user. Stated on the interface and witnessed instead.

**Claim 4 is now the owner's and the lead says so.** `RpcInMemoryTransport.pair` and
`RpcChannelTransport.memoryPair` are one factory under two public names; picking one is a breaking
rename, so the lead carries `awaiting owner` for that alone and no later round can rename public API on
its way past. Three options are written on it, with my judgement marked as a judgement.

**`lint` caught the bookkeeping, which is worth recording**: naming that lead in `## Target` is refused
outright — "a round may not take an unanswered question as its target; that decides it". The target is
the two claims; the lead's new status is a result of the round, not its subject.

## Links

Lead `../backlog/B-174-in-memory-payload-aliasing-and-close-asymmetry.md` — claims 2 and 3 answered,
claim 4 left to the owner, so the lead stays open.
Round `575-the-bytes-the-sender-kept-writing-to.md` — claim 1.
Round `573-the-503-written-to-a-dead-socket.md` — where the same one-turn yield WAS the fix, and why
it is not here.
Bench `../probes/P-197-what-a-channel-close-keeps.md` — new.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [576]`.
Lesson: none, and the candidate is worth naming to decline: "a one-turn yield that fixes a drop can
delay a cascade something else depends on". That is `L-01`'s shape — one half masking the other's
witness — already written, and the instance is recorded here.
