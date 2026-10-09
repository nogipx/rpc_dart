---
round: 510
verdict: FIXED
packages: [rpc_dart]
lens: RPC-16
bench: P-148 — new
commit: yes
severity: S2
---

# Round 510 — one call, answered three times

## Target

The frame count of a unary call — twenty-sixth in the audit's rank, and the first
COST-class lead of the run. What the count turned out to contain is the round.

Lens RPC-16, *check before await*, in the form that keeps recurring: a guard whose
condition depends on state that a detached future has not cleaned up yet.

## Hypothesis

The lead: a unary call is five frames, three of them JSON metadata, and initial
headers go out even for calls that fail.

## Before

Responder to caller, per call, frames decoded:

```
succeeds        4: window-update, content-type, DATA, grpc-status 0
handler throws  3: window-update, content-type, grpc-status 7
no such method  4: window-update, grpc-status 12, grpc-status 12, grpc-status 12
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b119_frames_per_unary_call.dart`

**The cost claim is wrong in both directions, and the last row is a defect.** A
success is 7 frames across both directions rather than 5, and 5 of them are metadata
rather than 3. And one call to an unregistered method produced **three end-of-stream
trailers on one stream id** — `s3` on all three, so one call, not three.

That is a protocol violation anywhere the peer keeps stream state, and it triples the
cost of the cheapest hostile input there is: probing for method names.

**Printing what each frame IS, not just counting, is what found it.** A count of 4
for that row is unremarkable beside the success row's 4.

## Mechanism

The responder has three `binding == null` sites — one on the metadata frame, one on
the data frame, one on the half-close — and each calls `_sendGrpcErrorAndCleanup`
through `_detached`.

That helper already knows about this: it calls `_rememberClosedStream(streamId)`
**synchronously, before the first await**, with a comment saying that is the whole
fix, added by an earlier round for the two-frame version of this.

But the guard that consults the set reads:

```dart
if (_respStreams[message.streamId] == null &&
    _respClosedStreams.contains(message.streamId)) {
```

The teardown that removes `_respStreams[id]` runs in the detached `finally`. So
between the synchronous mark and the cleanup the state is still there, the first
condition is false, and every further frame of the same call walks straight past the
guard into another refusal. **The earlier fix made the mark synchronous and left the
reader asynchronous.**

## After

```
no such method  2: window-update, grpc-status 12
```

The `_respStreams[id] == null` precondition is gone: membership of the closed set
alone gates the frame. A frame carrying `methodPath` AND metadata still clears the id
for reuse, which is the half of the guard that was load-bearing.

Both other arms are byte-for-byte unchanged.

Regression: `test/endpoint/one_call_gets_one_terminal_status_test.dart`,
1 WITNESS and 4 GUARD.

## Canary

The precondition restored. The WITNESS fails, `Expected: <1> Actual: <3>`, and prints
the three identical trailers. All four GUARDs stay green.

Two of those guards exist because the fix REMOVES a condition, which is the risky
direction: *a released stream id is still reusable by a NEW call* (six calls in
sequence, since the caller reuses ids as they are released) and *a refused call does
not poison the next one on that id*. If the closed-set entry were never cleared, the
next call would be ignored and hang to its deadline — a worse defect than the one
being fixed.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant. `analyze` failed once on an
`unnecessary_import` in this round's own test, and `format` once on the same file.

## Not fixed

**The lead's actual subject — the frame count — is untouched.** A success is still 7
frames, 5 of them metadata. Reducing that means sending initial headers with the
first response or folding them into the trailer, which is the lead's own sketch and a
protocol change.

**Trailers-Only for a handler that fails is still not done.** The `handler throws` arm
still shows `content-type` going out before the trailer, so a call that fails after
initial headers costs two frames where gRPC allows one. That is exactly what the lead
names and it is a different change from this one: this round stopped a call being
answered three times, it did not change when the FIRST answer is sent.

**A binary header encoding** — the lead's other half — is a wire change and the
owner's.

## Links

Lens RPC-16. Bench P-148 (new). Lead B-119 (awaiting owner: the cost half is measured
and refuted in its details, the remaining work is protocol). The earlier round that
made `_rememberClosedStream` synchronous is the one whose fix this completes.
