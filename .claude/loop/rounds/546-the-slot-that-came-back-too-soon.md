---
round: 546
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-157 — reused
budget: probes 2/5, canaries 3/5
commit: yes
release: breaking
severity: S2
---

# Round 546 — the slot that came back too soon

## Target

B-128, an owner decision and therefore the round's first target: **count until COMPLETION**, so
the slot is held until the call ends rather than until it half-closes.

Lens RPC-08: one field name, two sides counting different intervals.

The decision named one thing as unestablished — *"which event is the right end is still not
established by measurement — `releaseStreamId`, the terminal inbound frame, or both"* — and
said the round settles it first. It does, and the answer is BOTH, for different endings.

## Hypothesis

`finishSending` and the endStream sends release the slot, so `maxActiveStreams` on a client
counts calls that are still SENDING rather than calls that are outstanding.

## Before

```
4 calls started and parked awaiting their responses
after starting 4 MORE: 0 completed so far, 0 refused with RESOURCE_EXHAUSTED
  -> the ceiling did NOT bound them: it counts sending, not outstanding
```

Bench `../probes/P-157-what-the-client-ceiling-counts.md`, reproduced at today's sha.

## Mechanism

**Five send-side sites released the slot**, all of them at a half-close: `sendMetadata` with
`endStream`, the three `sendMessage`/`sendDirectObject` endings through `_markFinished`, and
`finishSending`. A unary call half-closes the moment its request is out, so its slot was free
while it waited for the response.

`_markFinished` did two things and only one was premature. Recording the ending is what stops a
repeat ending, and the parked-send branch reaches it without going through `_claimEnding`, so
the record has to stay; the release does not. `_markFinished` now only records, and the two bare
`_releaseStream` calls at the other endings go through it.

**The right end was already implemented, twice, and the canaries below say which covers what:**

```
  ending                  released by
  completion              the terminal inbound frame (_onMessage)
  an error status         the terminal inbound frame
  a deadline              releaseStreamId
  a cancel                releaseStreamId
  peer never answers      releaseStreamId
```

So neither is redundant: a call that ends WITHOUT a terminal frame is exactly the set
`releaseStreamId` covers, and the caller pipeline performs it in a `finally` for every call.

## After

```
4 calls started and parked awaiting their responses
after starting 4 MORE: 4 completed so far, 4 refused with RESOURCE_EXHAUSTED
  -> the ceiling bounded them

  ending                   admitted  REFUSED  other   (of 4, ceiling 2)
  completion                     4        0      0
  error status                   4        0      0
  cancel                         4        0      0
  deadline                       4        0      0
  peer stops answering           4        0      0
  CONTROL overlapping            0        2      2   <- refuses, so the instrument works
```

The second table is `../probes/P-177-does-every-ending-return-the-slot.md`, built for the
failure mode the decision warned about.

## Canary

**Three, and two of them told me something I did not know.**

```
A. the release restored at half-close (`_markFinished` releases again)

   WITNESS a call parked on its response still holds its slot
     Expected: <4>
       Actual: <0>

   Only the witness failed. All five ending arms and the control stayed GREEN,
   which is right: releasing early fails to BOUND, it does not leak.

B. the terminal-frame release removed (_onMessage)

   ALL SEVEN TESTS PASSED.

C. `releaseStreamId` stops freeing the slot

   every ending returns the slot / a deadline
     Expected: empty
       Actual: ['refused', 'refused']
     got [status 4, status 4, refused, refused]

   and the cancel and peer-never-answers arms with it. `completion` and
   `error status` stayed GREEN.
```

**Canary A first failed as a TIMEOUT**, which is not a real message. The witness awaited the
second batch to completion, and when the slots are released early all eight calls are admitted
and park on the handler — so the assertion could never be reached. A refusal is immediate and an
admission parks, so the batch is now polled with a short timeout and the failure reads
`Expected: <4> Actual: <0>`.

**Canary B passing is the finding, not a defect in the test.** It shows the terminal-frame
release is not what returns the slot in any arm here — `releaseStreamId` gets there too. Canary C
removes that mask, and then exactly the three endings with no terminal frame fail. Together they
establish the table above, which is what the decision asked for and what a single canary would
have hidden.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          2115 / 2115, REUSE compliant
```

`format:check` failed once on the new test and was re-run green; the transport suite was re-run
after formatting.

## Not fixed

**The streaming shapes are unmeasured**, which B-128's own `## Still unmeasured` already said. A
client-stream call holds its request stream open, so it may have been counted for its whole life
even before this change — meaning the field's meaning varied by SHAPE as well as by side, and
this round only measured unary. The change is shape-agnostic (it removes a release at
half-close, which is where every shape's request side ends), but no arm drives a client-stream
or bidi call.

**The SERVER side is untouched and was already correct** — B-128's measurement found the server
refusing at the interval its name implies. Worth stating because the lead is about the two sides
disagreeing, and this closes the gap by moving the client, not both.

## Links

Lead `../backlog/B-128-the-client-active-stream-count-ends-at-half-close.md` — closed by
this round; its owner decision is what the fix carries out.
Bench `../probes/P-157-what-the-client-ceiling-counts.md` — reused, reproduced at today's sha.
Bench `../probes/P-177-does-every-ending-return-the-slot.md` — new, for the opposite failure.
Round `536-the-release-that-freed-only-bookkeeping.md` — the sibling shape B-128 cites: freeing a
slot without stopping the work inverts a limit.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [546]`.
