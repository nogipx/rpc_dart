---
round: 547
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-08
bench: P-155 — reused
budget: probes 1/5, canaries 4/5
commit: yes
release: none
---

# Round 547 — the second revert

## Target

B-126, an owner decision and therefore the round's first target: **take the unary lifecycle
change**, so a transport that fragments is tolerated.

**The fix was built, both witnesses passed, and it is REVERTED.** `lib/` is byte-identical to
its committed state. Round 518 reverted this same lead once; this is the second time, for a
reason neither that round nor the decision had reached.

## Hypothesis

`handleMessage` claims the request before parsing, so the first fragment consumes the call and
answers INTERNAL. Parsing first, feeding every buffered fragment, routing later ones and
answering a mid-frame half-close makes unary behave like the streaming shapes.

## Before

```
CONTROL whole frames        unary got:64        server stream got:64   client stream got:64
each frame split in two     unary status 13     server stream got:64   client stream got:64
```

Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md`, reproduced at today's sha.

**The reachability reading the decision asked for, first.** No shipped transport fragments:
http2's responder keeps a per-stream `RpcMessageParser` with `emitFramed: true`, the frame
channel reassembles, HTTP/1.1 buffers the whole body. So the witness has to be built, exactly
as the lead says, and this is a capability change rather than a defect repair.

## Mechanism

What was built: three parts the decision named, plus two it did not.

1. parse BEFORE claiming the request, and treat an empty parse as incomplete;
2. feed every buffered pre-bind message, not just the first;
3. route a later data frame to the bound unary responder;
4. answer INVALID_ARGUMENT when the peer half-closes mid-frame;
5. keep the per-stream state (which owns the parser) while a frame is incomplete.

Part 5 is the one nobody had reached: the parser lives on the per-stream state, so the existing
`finally` that dropped that state after every message threw away the buffered prefix — and the
next fragment would then parse as the start of a frame, which is silent corruption rather than a
hang.

## After

```
each frame split in two          unary got:64
peer stops mid-frame             unary status 3: ... the last gRPC frame is incomplete
fragments reordered ahead of
  their metadata                 unary got:64
```

Both arms the decision required, passing. Two new bench arms were needed for them — `truncate`
and `reorderMetadata`.

**And this is the state that was reverted anyway.** A green witness was not enough, which is the
round's point: the gate reached cases the bench did not.

## Why it is reverted

**`RpcMessageParser` returning no messages does not mean "incomplete".** It also means
"refused": the parser throws for a frame over `maxMessageLengthBytes`, but a frame whose
declared length is not yet readable, or which is rejected further in, yields an empty result
that is indistinguishable from a partial one.

The gate caught it. A 32 MB payload compressed against a **1 MB configured policy**:

```
expected  contains 'max: 1048576'                       (RESOURCE_EXHAUSTED, the operator's limit)
actual    'RpcStatusException(3): Request stream closed mid-message
           for Svc.sink: the last gRPC frame is incomplete'
```

A security control reporting the wrong status and no longer naming the limit it enforces. That
is worse than the INTERNAL this round set out to remove, and it is not a wording problem: the
whole design rests on a distinction the parser does not expose.

**So a third attempt must take that distinction FROM the parser** — it knows whether it holds a
partial frame — and not from the emptiness of its result. Both witnesses are kept in the tree
SKIPPED with that condition written into the skip, per L-17.

## Canary

Four, and they are the reason the round can say which parts were load-bearing:

```
A. the incomplete branch throws INTERNAL again
   fragmented unary -> status 13. The original defect, exactly.

B. feed only the FIRST buffered message
   NO CHANGE in any arm, including one BUILT for it (fragments reordered ahead of
   their metadata). Part 2 is unwitnessed: layer 3's routing reaches every case.

C. the later fragment is not routed
   fragmented unary -> status 3, a clean failure rather than a success. So routing
   is what makes the call WORK; it is not what prevents the hang.

D. the mid-frame half-close guard removed
   truncated unary -> status 4: Deadline exceeded.
   Round 518's regression, reproduced exactly. THIS is what prevents the hang.
```

Canary B is the one that mattered most before the gate did: a canary that passes means the test
is wrong, and an arm was built specifically to see part 2. It still passed, so part 2 went in
unwitnessed — recorded rather than claimed.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          REUSE compliant
melos run test:unit --no-select  All tests passed, 2 skipped
```

**The FIRST test:unit run on the built fix was RED — five tests** — and that is the round's real
finding. Three were explained and fixed during the round: `requestHandled` read the per-stream
state, which `handleMessage`'s `finally` removes, so a COMPLETED call reported "still arriving"
and the pipeline skipped the teardown it owed (an undisposed call scope and an unreleased http2
endpoint were two of the five). One test legitimately pinned the old incidental status of a
truncated stream. The fifth is the `maxMessageLengthBytes` regression above, which has no fix
within this design.

Also worth recording: a background gate run reported **exit code 0 while failing**, because the
command was piped through `grep` and the status read was the pipe's. Same trap as round 543's
`test:web` claim, two rounds apart.

## Not fixed

**B-126 stays `decided by owner`.** The decision stands and is not reversed by this — what is
established is the constraint any implementation must satisfy. That constraint is now in the
lead, in the skip reason, and here.

**B-216 is new and independent**: a server stream left waiting to its deadline on the same
truncated frame, measured with the fix in place and with it ablated. Nothing in this round
changed that shape; the arm that revealed it exists because the decision demanded it.

## Links

Lead `../backlog/B-126-unary-assumes-one-message-per-transport-frame.md` — CLOSED in
round 553, which took the step this round named. It was still open here, with the
blocking constraint recorded.
Lead `../backlog/B-216-a-server-stream-hangs-on-a-truncated-frame.md` — new here, CLOSED
in round 554.
Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md` — reused; `truncate` and
`reorderMetadata` arms added.
Round `518-the-fix-that-turned-an-error-into-a-hang.md` — the first revert of this lead.
Lesson `../lessons/L-17-a-skip-states-its-conditions.md` — applied: the two witnesses are kept
skipped with their condition, not deleted.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [547]`.
