---
round: 423
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-94 — new
commit: yes
---

# Round 423 — the third route

## Target

**B-57**, the owner's decision to *"spend a round looking for a THIRD route"*.
Both known routes were closed:

- keep the subscription — the fan-out stays O(N) per frame;
- `getMessagesForStream(id)` — REFUTED in the lead's own record: it creates a
  per-stream controller, and `_admitToStreamBuffer` can refuse a frame and
  return before the unconditional `_incoming.add`, so a large unary request
  would be dropped by a bound that does not apply to unary today.

The decision permitted producing a number and no fix, if no third route existed.

## Hypothesis

There is a third route, and it is about WHERE the handler subscribes.

**Wrong, and that is why the first two failed.** Both are about where the
handler subscribes. The third route is that the handler does not subscribe at
all, because the duty is not the handler's.

## Before

P-94, counting listeners on `incomingMessages` with N unary handlers parked:

```
parked handlers   listeners
      1                2
     10               11
     50               51
    200              201
```

Exactly N+1 — the pipeline's own, plus one per live handler. Each is invoked for
every inbound frame and its first act is `if (id != 0 && streamId != id) return`.

And for a pipeline responder the subscription **delivered nothing**: the
pipeline builds it with `id: streamId` and hands it the request four lines
later.

## Mechanism

What the subscription really carried was its `onError`. The lead is precise
about why round 393 would not drop it: a transport error that does NOT close the
stream was answered there and nowhere else, because
`responder_pipeline.dart`'s own `onError` **logged only**.

So the question was never "where should the handler listen" but **"whose duty is
it to answer a connection-level error"** — and the answer is the connection's,
which has one subscription, not the handler's, which has N.

## After

```
parked handlers   listeners
      1                1
     10                1
     50                1
    200                1
```

`UnaryResponder` gains `listensToTransport`, false when the pipeline builds it.
The pipeline's `onError` gains `_answerActiveStreams`: it skips advisory errors
for the same reason the old listener did, then answers every active stream with
`wireStatusFor(error)` — default-deny, so a foreign error is redacted — and
aborts them.

`onDone` stays separate and unchanged: there the transport is gone, so there is
nothing to answer over and `_abortActiveStreams` only has to reclaim. This path
is the one where the caller is still reachable.

## Canary

```
listensToTransport: true        "one listener on the connection, whatever the
  (the pre-fix behaviour)        load" -- Expected: 1  Actual: 2
                                 and the GUARD stayed GREEN
```

The GUARD is the load-bearing half: *"the handler still gets its answer"* drives
a transport close under a parked call and requires the caller to be told
something rather than wait out its own deadline. It passes on both sides of the
ablation, which is what says the duty survived its move rather than being
dropped with the subscription.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**The question the lead wanted measured is still unmeasured, and the fix made
it moot rather than answering it.** It asks whether a non-advisory transport
error ever arrives WITHOUT the channel then closing — because if not, the old
`onError` saved nothing. That reading was never taken. It stopped mattering
because the duty now lives on a subscription that exists either way, so the
answer changes nothing about what to build; but it is a question this round
declined rather than settled, and a future round wanting the negative still has
to take it.

**Only the unary shape changed.** The three streaming shapes route transport
errors through `StreamProcessor`'s request controller and were never part of
this fan-out. `_RpcZeroCopyUnaryResponder` does not subscribe either.

**A directly-constructed `UnaryResponder` still subscribes**, by design: it has
no pipeline to feed it or to answer for it. Two tests rely on that
(`unary_advisory_error_test`, `call_shapes_cannot_kill_the_process_test`), and
they keep the old path covered.

**The per-frame COST is not measured**, only the listener count. P-94 says so.

## Links

- B-57 — closed here
- P-94 — new
- RPC-25 — the duty was written N times because it was filed under the wrong
  owner; asking WHOSE duty it is, rather than where the code should sit, is what
  the first two routes both skipped
- round 393 — refused to drop the subscription without this answer, correctly
