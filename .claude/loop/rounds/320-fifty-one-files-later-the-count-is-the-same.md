---
round: 320
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-02
bench: none
commit: yes
---

# Round 320 — fifty-one files later, the count is the same

## Target

The first item on the queue round 319 established: RPC-02's sweep was a
statement about the tree at `0a6e25d5`, and 51 files have moved since — 19 of
them behavioural, several landing on the refusal path that is the lens's own
subject.

## Hypothesis

Nineteen behavioural commits across the refusal paths, including four of my own
refactors from rounds 308-315, will have added a trailer site that does not cap
its message — or moved an existing one out from under its cap.

## Before

The detector, run whole on the current tree: every `RpcMetadata.forTrailer` site
in `lib/` across core and the four transports, sorted by whether the trailer
passes through a validating hop.

```
                                          round 243   round 320
total assembly sites                          16          16
  pass a message                              12          12
    ...and carry maxMessageLength             12          12
  pass no message (always fit)                 4           4
```

## Mechanism

**Nothing rotted, and nothing new appeared.** All twelve message-passing sites
carry a cap:

```
responder_ping_handler.dart:82      _trailerMessageCap(transport)
unary/responder.dart:242,393,522    _policyOf(_transport).maxHeaderValueBytes
base_processor.dart:712             _policyOf(_transport).maxHeaderValueBytes
frame_multiplexed_channel.dart:261  _policy.maxHeaderValueBytes   (INBOUND)
frame_multiplexed_channel.dart:316  _policy.maxHeaderValueBytes
responder_pipeline.dart:1537,1565   _trailerMessageCap(transport)
http2_responder_transport.dart:138,385,562  _policy.maxHeaderValueBytes
```

and the four uncapped ones pass no message at all —
`forTrailer(RpcStatus.ok)` three times plus one
`forTrailer(RpcStatus.invalidArgument)` — so there is nothing to overflow.

The result worth keeping is not "still clean" but **the surface did not grow**.
Across rounds 244-319, with 19 behavioural commits along these paths, not one
new trailer site was written. That reframes where the lens's risk lives: not in
existing sites decaying, but in a NEW refusal path arriving without a cap — which
is exactly what rounds 237 and 240 did add, and both capped themselves without
consulting the lens.

## After

```
RPC-02   swept here (round 243, 0a6e25d5)  ->  swept here (round 320, 3228c5de)
```

## Canary

**This was a reading, not an ablation, and that is the third one in a row.**

Round 216 capped `maxHeaderValueBytes` to 64 and measured that statuses survived
and that removing the cap from ONE trailer turned status 8 into a raw
`ArgumentError`. That measurement is what gives "every site passes the cap" its
meaning. Round 243 re-read rather than re-ablated; so did this round.

Three readings do not add up to a second measurement. The lens now says so, and
says the next round to touch it should ablate instead — that is a stronger
result than a fourth reading would be.

## Gate

Not re-run: no code changed. Last full gate at round 315's `29acab93` — analyze
clean over 21 packages plus wasm, `test:unit` 14 packages 0 failures, format
clean, licence 1317/1317.

## Not fixed

Three re-sweeps remain on 319's queue: RPC-09 (34 files, deadline below the
write), RPC-14 (33, timeout abandons work), RPC-19 (21, one flag two lifecycle
meanings).

The ablation this round declined to do is now written into the lens as the next
action for it, rather than left as an unstated debt.

## Links

RPC-02 (`applied:` gains 320, status re-dated to `3228c5de`), RPC-15 for the
re-measurement discipline that produced the queue.

What this adds to RPC-02: a sweep's value is partly in the COUNT over time. Two
sweeps 77 rounds apart returning 16/12/4 unchanged says the surface is stable,
which is a different and more useful claim than either sweep alone.
