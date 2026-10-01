---
round: 565
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-17
bench: P-187 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 565 — the canary that reported a pass

## Target

B-184's last item, the `_halfClosedLocal` leak, for the third round running. Round 563
swept the three add sites and declined the one-line guard for want of a witness; round 564
set out to build one, concluded the map could not be filled by any shape a test can drive,
and named the rig the next round would need. Taking the started thread over anything new is
the judgement rounds 234-238 paid for.

Lens RPC-17: a ledger whose growth nothing watches.

**The rig round 564 named was not needed, because its central claim is false.** That is
this round's second result and the more expensive one.

## Hypothesis

`sendMessage` adds the id to `_halfClosedLocal` after awaiting the pump, so a release
landing in that window leaves one entry per stream. Round 564's counter-hypothesis — that
no drivable shape populates the map at all — is testable by the same ablation it reported.

## Before

```
WITNESS  reset lands while the endStream send is parked
parked=true threw=null
    while parked  {activeStreams: 1, halfClosedLocal: 0, outgoingPumps: 1}
    after reset   {activeStreams: 0, halfClosedLocal: 1, outgoingPumps: 1}

CONTROL  window opens first, so the send completes BEFORE it
    while parked  {activeStreams: 1, halfClosedLocal: 0, outgoingPumps: 1}
    window open   {activeStreams: 1, halfClosedLocal: 1, outgoingPumps: 1}
    after reset   {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 1}
```

One entry held on a stream that no longer exists, against zero for the same frames in the
benign order. Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/b184_halfclosedlocal_leak.dart`.

And round 564's own ablation, re-run on its own test:

```
both removals dropped, every_per_stream_map_returns_to_zero_test
  Expected: <0>
    Actual: <10>
```

**Ten — one per call, across five unary and five server-stream.** Round 564 reports both
ablations PASSING and concludes the shapes never populate the map. They do: the unary
caller passes `endStream: true` to `sendMessage` (`unary/caller.dart:559-563`,
deliberately unawaited), so the add site is reached on every unary call.

## Mechanism

A peer RST_STREAM does two things in one frame. It ends the incoming side, so the inline
release at `rpc_http2_caller_transport.dart:1223-1229` clears every per-stream map; and it
cancels the outgoing sink, so the pump's `onCancel: _wake` releases whatever is parked on
the window. The woken `add` then returns normally — the pump was never disposed, so round
558's throw does not apply — and `sendMessage` re-adds the id to a set that was cleared
while it waited.

Of the three add sites, only this one sits behind an await, which is round 563's sweep and
it holds: `:908` sets `_activeStreams[streamId]` immediately before its add, and
`finishSending`'s `:1059` follows two synchronous calls.

## After

```
WITNESS  reset lands while the endStream send is parked
    after reset   {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 1}

CONTROL  window opens first
    window open   {activeStreams: 1, halfClosedLocal: 1, outgoingPumps: 1}
    after reset   {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 1}
```

`if (endStream && _activeStreams.containsKey(streamId))` — the identity question round 541
used in core's `_cleanupStream(only:)`. The control's `window open` row is unchanged, which
is what says the fix skips the add only when the stream is gone rather than always.

## Canary

```
if (endStream && (1 > 0 || _activeStreams.containsKey(streamId)))

  WITNESS  Expected: <0>
             Actual: <1>
           the woken send put the id back into a set the release had already
           cleared, and nothing removes it again
  CONTROL  still passes
```

The control staying green under the ablation is the virtue `canary.md` item 8 names: the
new test isolates the new defect rather than the rig.

**Two guards stand in front of that assertion**, because a zero here is exactly the shape
round 564 misread: the witness asserts `parked == true` before anything else, and the
control asserts `halfClosedLocal == 1` while the stream is still live. Without the second,
a witness reading 0 cannot be told apart from a map nothing ever fills.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   rpc_dart_http2 +259
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2161 / 2161, REUSE compliant
```

## Not fixed

**A parked send reports SUCCESS after the peer resets the stream.** The probe reads
`threw=null` on the witness arm: the pump is not disposed, so `_controller.add` accepts the
payload and the sink it would drain into is already cancelled. That is round 558's class —
a send that did not reach the peer must not read as success — on the path round 558 did not
cover, since its arm disposed the pump. Whether the payload reaches the wire is NOT
measured here; the probe reads the transport's maps, not the server's bytes. Filed as
`B-221`.

**The pump outlives the reset** (`outgoingPumps: 1` in every arm after it), because the
inline release clears seven maps and `_outgoingPumps` is not among them —
`releaseStreamId` is the only path that disposes it. Through `RpcCallerEndpoint` that is
harmless: the `STACK` arm reads `outgoingPumps: 0`, because the pipeline releases the id
when the call ends. For a direct transport user it is one pump per reset stream until they
release. Same lead, `B-221`.

**Why round 564's canaries read as passes is not established.** The ablation it describes
fails at this sha, and nothing changed those lines in between (`git log` on the file since
`981c435b` is this round alone). Whether the edits landed elsewhere, or the test was not
re-run, cannot be recovered from the record, so the finding is stated as "the claim is
false" rather than explained.

**The `_waiters`-overtaken-by-a-new-add item is still unmeasured** — named by B-184 and a
different shape from this; ordering two concurrent sends on one stream is the caller's job
today.

## Links

Lead `../backlog/B-184-http2-send-message-races-after-its-await.md` — the last item CLOSED;
the lead closes with it.
Lead `../backlog/B-221-a-parked-send-reports-success-after-a-peer-reset.md` — new, holds
what this round did not fix.
Round `564-the-unreported-map-and-a-vacuous-zero.md` — its canary conclusion is corrected
here, and its record now says so.
Round `558-the-half-close-overtook-the-payload.md` — the pump half of the same lead.
Bench `../probes/P-187-does-a-release-during-a-parked-send-leak-its-id.md` — new.
Lesson: none. The rule round 564 broke is already written twice — `measurement.md` item 8
("zero is suspicious: check whether the mechanism could emit anything at all") and
`canary.md` item 7 — and the post-348 curate pass already declined "an arm reporting zero
must prove it could report one" as a lesson of its own. What this round adds is an instance,
which belongs here.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [565]`.
