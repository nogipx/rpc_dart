---
round: 825
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-01
bench: P-306 — new
commit: yes
release: none
---

# Round 825 — a refused decode returns its credit

## Target

RPC-01, ranked first by the curate pass after round 824 (14 S1, the last in
round 802). Its shape is a message dropped without its flow-control credit.
Round 803 added a new way to drop one: the CBOR item budget refuses a
message at decode, and the call is torn down with frames still in flight.

## Hypothesis

A message refused at decode, or the frames that follow it on the torn-down
stream, are never credited back, so each refusal shrinks the connection
window until every call on the connection stalls (S1: every call dies).

## Before

```
P-306 control: honest 1.2 MB stream through a 256 KiB window, 0 refusals:
  20 of 20 in 63 ms
```

## Mechanism

n/a (CLEAN). Credit is given on delivery (`onConsumed`), before the decode,
so the refusal cannot skip it; the frames after it are credited by the
torn-down stream's drop path (round 738).

## After

```
  refusals (x10 messages of 60 KB)   honest stream
  2                                  20 of 20, 15 ms
  10                                 20 of 20, 10 ms
  30                                 20 of 20, 9 ms
```

## Canary

`onConsumed` crediting nothing, in place: the honest stream at 0 refusals
ends `RpcDeadlineExceededException` after 5020 ms. The window binds on this
pair, so the bench would see a leak. Restored.

## The verdict questions

1. Only the number of refused streams differs.
2. Yes: with credit removed the same honest stream stalls.
3. At the caller: whether the honest stream arrives.
4. 30 x 10 x 60 KB offered against a 256 KiB window: a leak of any one
   refusal's bytes would show.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. Only the client's policy is narrowed; the server's is default.
A2. Volume. L1. n/a.

## Gate

No code changed; the ablation was reverted, the probe is outside the tree.

## Siblings

No code changed. websocket and isolate share core's flow controller; the
http transport has no flow control; http2 has its own and the budget there
is the same core decode.

## Not fixed

none.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md`. Bench
`../probes/P-306-credit-after-decode-refusals.md`. Negative
`../checked/C-78-a-message-refused-at-decode-returns-its-credit.md`.
