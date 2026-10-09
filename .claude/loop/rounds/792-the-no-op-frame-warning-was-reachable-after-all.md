---
round: 792
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: none — the observable is a count of warning records per connection, read by overriding LogController.add in round 604's test rig
commit: yes
release: changelog
---

# Round 792 — the no-op frame warning was reachable after all

## Target

KV-R-10 continued. Round 791's deadline arm, built wrong at first (it
dropped the method path from its metadata), hit `Ignoring no-op frame for
unknown stream N` once per call. Round 604 left that site unguarded because
round 515 could not reach it ("the frames do not reach
`_processResponderMessage` at all", INCONCLUSIVE); `loop.py find "Ignoring
no-op frame for unknown stream unreachable round 515"` names only those two.
Taken on the evidence of a frame that does reach it. The deadline arm itself,
rebuilt with the path kept, wrote 0 records on all four shapes.

## Hypothesis

A metadata frame with ordinary request headers and no method path, on fresh
stream ids, writes one warning per frame.

## Before

Round 604's rig (`a_peer_cannot_flood_the_responder_log_test.dart`: a raw
client `RpcChannelTransport` over `RpcFrameMultiplexedChannel.pair()`,
records counted in `LogController.add`), five such frames:

```
  Expected: <1>
    Actual: <5>
  [Ignoring no-op frame for unknown stream 1, ... 3, ... 5, ... 7, ... 9]
```

## Mechanism

`_processResponderMessage` warned unconditionally for a frame that opens
nothing on an unknown id. Round 515's hand-built frames were dropped below
the pipeline; a frame carrying the client's own request headers (content
type, te, user agent) without a path is delivered, and lands here.

## After

The same test: `1`. One bool, `_warnedNoOpFrame`, the shape of the five
sites round 604 guarded beside it.

## Canary

The before-run above is this code with the guard absent: `Expected: <1>
Actual: <5>` with the five messages listed, as round 604 recorded its own.

## The verdict questions

1. One thing varied: the guard. The frames, the rig and the count are
   round 604's.
2. Yes: 5 against 1.
3. Library side: `LogController.add`, before filtering.
4. n/a — the count after is 1, not 0, and the before-run shows 5.
5. Yes, quoted.
6. One half.
7. FIXED.
8. Round 515's "unreachable" was a record, and it was not taken as
   evidence: the site was reached today. Its other unwitnessed site
   ("endpoint is not started") stays unguarded: still no peer-driven frame
   reaches it.
9. None.
A1. One process; client transport with its windows off, server its own
    default policy.
A2. Volume: frames per connection.
L1. n/a.

## Gate

`fvm dart format` on the two files, then `melos run analyze` green (L-24);
`melos run test:unit --no-select` green (15 packages, rpc_dart +2127 ~1);
`melos run format:check` green; `melos run license:check` green. `fvm dart
test -p node` on the test: 6 of 6.

## Not fixed

"Endpoint not started" (`responder_pipeline.dart`): no witness, round 515's
reason holds.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`.
Round `604-the-peer-chose-how-many-lines.md`.
Round `515-the-rig-never-reached-the-warning.md`.
Round `791-a-cancelled-client-stream-was-a-warning-per-call.md`.
Lesson `../lessons/L-24-analyze-after-the-last-format.md`.
