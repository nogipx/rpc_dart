---
round: 383
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-07
bench: P-71 — new
commit: yes
---

# Round 383 — slicing the wire does not do it

## Target

B-44, at the owner's direction. A consumer's client-stream upload arrives with
the first message's identity fields null — `blobId`, `vaultId`, `totalLength` —
**86 times in 3.6 days across two replicas**, on dart2js through a browser
WebSocket, never on the VM.

The 2026-09-15 session built P-51, eliminated four candidates and did not
reproduce it. Its own ranked list of what was left put **the network path**
second: production is `wss://` through a Caddy ingress, the bench was a bare
local socket, and "a proxy that splits or coalesces frames is the kind of
difference that would not show anywhere else".

That is the angle this round takes, because round 378 put a tool for it in
reach: toxiproxy's **slicer**, which cuts writes at boundaries the sender never
chose — the sharpest form of that difference for a framed protocol.

RPC-07: the defect is reported on a runtime the ordinary gate does not run.

## Hypothesis

A write split at an unchosen boundary makes the first message decode against the
wrong bytes, or lose its fields.

## Before

17 chunks, the first carrying the identity and the rest payload only — the
consumer's exact shape — with every field a function of the index so that a
lost, reordered, duplicated or mis-decoded message is distinguishable:

```
arm                        result
direct, small              first ok (index=0) | handler got 17
direct, 256 KiB chunks     first ok (index=0) | handler got 17
SLICED, small              first ok (index=0) | handler got 17
SLICED, 256 KiB chunks     first ok (index=0) | handler got 17
```

Probe:
`packages/transport/rpc_dart_websocket/.dart_tool/probe/first_chunk_fields_under_slicing.dart`
(P-71). Real websocket server, the client through toxiproxy with a `slicer`
toxic on the upstream — `average_size: 128`, `size_variation: 64`,
`delay: 1000`.

**Not reproduced.** Slicing the wire under a client-stream upload changes
nothing: WebSocket framing reassembles above TCP, so a split at an arbitrary
byte offset is invisible to the parser.

## Mechanism

n/a — nothing found.

## After

n/a — no change made.

## Canary

An ablation dropping a client-stream's request frames in
`_handleDataMessage` took every arm from `handler got 17` to `handler got 0`, so
**the probe can see a delivery defect**. Tree restored, `git diff --stat` empty.

**This is weaker than the round needed and the verdict follows from that.** The
ablation was meant to drop only the FIRST frame and produce the consumer's exact
symptom — `FIRST CHUNK HAS NULL IDS` — and instead it removed the responder's
dispatch as well, so what was demonstrated is that the probe distinguishes
*delivered* from *not delivered*, not that it would recognise the specific
shape. A bench that has not been shown to see the defect makes the verdict
INCONCLUSIVE rather than CLEAN (`measurement.md` item 10).

## Gate

No library code moved — `git diff --stat` empty before the verdict — so round
382's gate stands. The toxiproxy container this round created was removed.

## Second pass — the candidate, read rather than guessed at

The round did not stop at the slicer. `e4238948`, which this record named as
"candidate to check first", **is in the consumer's build**
(`git merge-base --is-ancestor e4238948 55159adf` → true), so it cannot be
excluded on version grounds. Its diff is one clause:

```
-      if (message.methodPath == null) {
+      if (message.methodPath == null || message.metadata == null) {
```

A frame for a stream in `_respClosedStreams` used to be admitted whenever it
carried a methodPath; now it must carry metadata too, and **a DATA frame has
none**. So a first payload frame for a released id is dropped where it used to
revive the stream — the direction B-44's symptom needs, and a direction the
commit's own reasoning never considers.

For it to fire, the state must be GONE while the call is live. Two routes:

- **id reuse — ruled out.** `generateId()` restarts only when the 2^31 range is
  exhausted with nothing in flight.
- **half-open reclaim — measured, and ruled out too:**

```
arm                             result
fast start, 300ms window        first ok (index=0) | handler got 5
stall 600ms, 300ms window       first ok (index=0) | handler got 5
stall 600ms, 30s window         first ok (index=0) | handler got 5
```

The generous-window arm is the control: the timeout was the variable, not the
stall. **A client-stream has no "opened and silent" window at all** —
`CallProcessor` sends its initial metadata with the FIRST message, or at the
half-close, so the server learns the stream exists at the same moment the first
chunk arrives. The reclaim timer is armed and cancelled in the same breath.

Bidirectional IS the shape with that window, and only since round 373 announced
the call in the caller's constructor. Worth remembering; not this defect.

Probe: `packages/core/rpc_dart/.dart_tool/probe/first_chunk_after_half_open_reclaim.dart`.

## What was fixed, once the search was exhausted

Every axis reachable from this repository came back clean — VM pipeline,
dart2js, real browser WebSocket, wire slicing, wire COALESCING (a 64 KB/s
bandwidth toxic, which makes writes arrive joined), id reuse, half-open reclaim,
the consumer's own `55159adf`, 40 sequential uploads on one connection, 20
concurrent. The owner's call at that point was to close it, and that is right:
the search was out of moves.

**But the reason it could not be diagnosed is itself a defect, and that is
fixable.** A request vanishing between the peer and the handler was SILENT: the
caller is told the call succeeded over a sequence the handler never saw. Both
ends report success over different data, which is why neither end's logs can
answer B-44's own question — *does the first message arrive and decode wrong, or
never arrive?*

The pipeline knows both numbers and now compares them as the call ends:

```
Request messages LOST for Svc.put [streamId: 1]: the pipeline accepted 17
and the handler was given 2 — 15 never arrived (dropped: 0)
```

`acceptedRequests` is counted where a frame is accepted for delivery — after
the method is resolved and the binding found, so a frame legitimately refused
above does not read as lost. `deliveredRequests` is counted where it reaches the
sink. Reported at `error`, never raised: by then the call has answered and there
is nobody left to fail.

This does not fix B-44. It makes the next occurrence one grep away instead of
unfalsifiable, which is what the consumer needs and what six rounds of guessing
could not provide.

## Canary

Dropping a chunk in `pushRequest` before the counter produced the line above;
restored, silent. **The first attempt at this canary was wrong and is worth
recording**: it incremented `deliveredRequests` and then dropped, so the two
counters agreed and the detector stayed quiet while the handler really did lose
messages. A canary that leaves the instrument blind reads exactly like a clean
run.

The GUARD test's assertion order was wrong for the same reason — a delivery
check ahead of the log check failed on the same canary and hid whether the
detector had spoken at all. The log assertion now comes first.

**Silence measured on every ending, not reasoned about.** A detector that fires
on an ordinary path is noise, and noise is the failure B-45 was filed for — 704
warnings a day drowning the one line that mattered. So all seven endings round
372 enumerated were driven at it:

```
ending                        LOST reported
healthy 17-chunk upload             none
handler stops reading early         none   <- the dangerous one
handler throws part-way             none
deadline expires mid-upload         none
caller cancels mid-upload           none
transport dies mid-upload           none
```

The early return is the one that looked certain to false-positive: the pipeline
accepts seventeen and delivers three, legitimately. It stays quiet because the
frames after teardown are discarded as trailing frames before the binding is
found, so `acceptedRequests` never counts them — the counter sits on the right
side of the tear-down by construction rather than by a special case.

## Not fixed

**B-44's cause.** Closed by the owner as not reproducible anywhere; five
suspects were eliminated in this round alone and the remaining two — Electron's
renderer, and the consumer's own code — are outside this repository. One more candidate is eliminated and that is the round's
whole product: the network path, in its splitting form, is not it.

What the ranked list still holds, unmeasured:

- **the pinned ref.** The consumer runs `55159adf` (6.0.0); every bench since has
  run HEAD, now ~30 commits further. Still the cheapest next step, and it is
  cheaper than when B-44 said so, because this round's probe takes a port and a
  chunk count and nothing else.
- **Electron's renderer** rather than plain Chrome.
- **coalescing** rather than splitting — toxiproxy slices, and the ingress may
  instead join writes. Not the same experiment.

And one thing this round should have done and did not: the ablation was
designed after the measurement rather than before it, which is how it came out
too blunt to certify the reading.

## Links

- RPC-07 — the lens; `applied:` gains 383
- B-44 — still open; this round removes one suspect from its ranked list
- P-71 — the bench, with its own weakness recorded
- P-51 — the 2026-09-15 bench, which eliminated the other four
- Round 378 — put toxiproxy in reach and named slicing as the interesting toxic
  for a framed protocol
