---
round: 376
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-66 — new
commit: yes
---

# Round 376 — the fix proven on one wiring

## Target

The owner asked what might have been missed. The honest answer began with the
round just shipped: **373's fix was proven on `RpcChannelTransport.pair()` with
a plain caller/responder pair, and that is one wiring out of several.** A fix
that covers the case you measured and not the ones you did not is the same
under-delivery as fixing a subset of a class (L-12), arrived at from the other
end.

RPC-15 — re-measure the loop's own record, including what a round claims its
fix is worth.

Three wirings, chosen because each reaches the dispatch by a different route:
the **peer endpoint** (filters inbound messages by stream-id parity), the
**zero-copy branch** of `_ensureBidirectionalResponder`, and **eight concurrent
calls** on one connection (shared pipeline, shared id space).

## Hypothesis

373's fix does not hold on at least one of them.

## Before

```
wiring              silent      control
peer endpoint       3 DONE      3 DONE
zero-copy           3 DONE      3 DONE
8 concurrent        8 of 8      n/a
```

`silent` is a caller that sends nothing and never half-closes — the subscription
373 fixed. `control` is the same handler with a request stream that CLOSES at
once, the case that worked before 373.

Probe: `packages/core/rpc_dart/.dart_tool/probe/bidi_subscription_everywhere.dart`
(P-66).

**Every value is a good one, so the round rests on the ablation.** Removing
373's metadata-frame dispatch:

```
wiring              silent      control
peer endpoint       0 HANG      3 DONE
zero-copy           0 HANG      3 DONE
8 concurrent        0 of 8      n/a
```

Every `silent` arm collapses and every `control` arm survives. That is two
statements at once: the probe sees the defect on all three wirings, **and the
defect was really present on all three** — so 373's fix is not merely untested
here, it is load-bearing here. Tree restored, `git diff --stat` empty,
re-measured back.

## Mechanism

n/a — nothing is broken. The dispatch lives in the shared pipeline, which is
what makes it reach all three, and the ablation is what turns that from an
argument into a measurement.

**One arm was invalid on the first run and it is worth recording**: the zero-copy
case reported `ArgumentError` in BOTH the silent arm and its control, which is
measurement.md item 4 — when the control shows the same symptom as the case
under test, the bench is wrong, not the library. `RpcChannelTransport.pair()`
does not support direct objects; `RpcInMemoryTransport.pair()` does. Read the
control before believing the case.

## After

n/a — no change made. The three wirings are now pinned by
`test/streams/bidi_subscription_on_every_wiring_test.dart`, so the coverage
cannot quietly regress.

## Canary

n/a — no fix. The ablation above is this round's variation and its whole
evidence, and it is stronger than a canary would be: a canary shows a fix is
load-bearing where it was written, while this shows it is load-bearing on three
wirings the fix's own round never ran.

## Gate

All four green: `melos run analyze`, `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check`. In the package
`fvm dart test -j 8` **+1545 ~1** (four new tests).

## Not fixed

Nothing found. What is still NOT covered of bidi, listed because the owner's
question was exactly this and a short list reads like a complete one:

- **Real transports.** Every bidi measurement in rounds 372-376 is on an
  in-process pair. `rpc_dart_http2`, `rpc_dart_websocket` and `rpc_dart_isolate`
  each build their own metadata frame, and whether a HEADERS-only open reaches
  the peer there is unmeasured. **This is the largest remaining gap** and it
  needs a transport-level bench, not another core one.
- **Latency.** The in-process pair flattens anything the size of a round trip
  (P-58's lesson), so the ordering result in 373 is about the pipeline.
- **The request direction of the pump** (`_pipelineFedRequestStream`), named in
  374.
- **`abort()`**, **deadline mid-duplex**, and **dart2js**.

## Links

- RPC-15 — the lens; `applied:` gains 376
- P-66 — the bench; its evidence is the ablation, not the good values
- C-42 — the negative
- Round 373 — the fix this round re-measured on wirings it never ran
- L-12 — a fix that covers the case you measured and not the ones you did not is
  the same under-delivery as fixing a subset, from the other end
