---
round: 601
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-155 — reused
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 601 — the bidi half-close nobody measured

## Target

B-218 item 1, the part the lead itself names as cheapest: round 554 fixed a
mid-frame half-close for server-stream and client-stream from one place in
`StreamProcessor`, and bidi "runs through that same helper and is therefore fixed by
construction and measured by nothing". Item 3 of the lead is answered by rounds
594, 595 and 600 (recorded below).

## Hypothesis

A bidi peer that sends half a gRPC frame and half-closes is answered with
INVALID_ARGUMENT, like the other two streaming shapes. Refuted if the bidi call
ends any other way, or if it gets the status even with round 554's answer removed
(then the witness would not be measuring the fix).

## Before

```
shape           fix on                    fix ablated
server-stream   status 3                  status 4 (deadline)
client-stream   status 3                  got:0 (success over nothing)
bidi            status 3                  '' (empty success)
```

Rig: `test/streams/unary_tolerates_a_fragmented_frame_test.dart`, the fragmenting
channel P-155 measures with; ablation is `holdsPartialFrame` in
`base_processor.dart` switched off in place and restored.

## Mechanism

All three streaming shapes reach the same `StreamProcessor` end-of-requests check;
without it bidi ends the request stream cleanly and the handler yields nothing, so
the peer sees an empty success over a message it did send.

## After

n/a — no library change. The bidi witness and a fragmented-but-complete bidi guard
are added to the test file.

## Canary

The ablation above: `WITNESS a bidi stream answers a mid-frame half-close` fails
with `Expected: a string starting with 'status 3', Actual: ''`.

## Gate

`melos run test:unit --no-select` (rpc_dart +1894, websocket +250, all 15 green),
`melos run format:check` green; the changed test file analyzed clean. No `lib/`
change.

## Not fixed

B-218 keeps two items: whether the CALLER side of a client-stream (item 1's third
bullet) depends on the dropped state, which the lead itself grades low-risk, and
item 2 — what memory a window's worth of wire bytes becomes once decoded, an RSS
measurement for the doc rather than a defect.

Item 3 answered: under an endpoint, the per-stream ledger refuses at 16 MiB (round
594, bidi `1023` retained), the connection total binds at the window (595), and the
connection-wide queue holds nothing (600).

## Links

Lead `../backlog/B-218-the-other-half-closes-are-unmeasured.md` — open, narrowed.
Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md` — reused.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [601]`.
