---
round: 610
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-22
bench: none — read
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 610 — what nobody in the stack reaches

## Target

B-225 items 2 and 3, the remainder after round 609: zero-copy payloads weigh 0
bytes against the connection total, and the pause contract on the channels other
than websocket was never checked.

## Hypothesis

Either item is reachable by a peer the library does not trust.

## Before

Read, not run:

```
item 2  directPayload exists only on in-process pairs (memoryPair, isolate
        handoff); its producer is the same program
item 3  pause/resume on IRpcChannel.incoming in core lib/      0 call sites
        IRpcChannel implementers outside core                 websocket, wasm
        isolate                                               not an IRpcChannel
```

## Control

Round 534's websocket witness, `a_paused_consumer_stops_the_reads_test.dart`, shows
that a paused `incoming` matters only to a caller holding the channel directly.
That is still the only kind of caller that can pause it.

## Mechanism

Item 2: a peer that can mint direct objects runs in the victim's own process, so
the bound would protect the program from itself. The per-stream EVENT ceiling
still applies. Item 3: rpc_dart never pauses a channel's `incoming`. The wasm
channel's source is a native push with no read to suspend. The isolate transport
has no `IRpcChannel`. What remained was `IRpcChannel`'s own doc example, which
showed the pause gap round 534 fixed in the websocket channel. Anyone copying it
copied the gap.

## After

The doc example forwards `onPause` / `onResume` to the socket subscription, and
`incoming`'s doc says a pause should reach the reads underneath.

## Canary

n/a — no behaviour changed.

## Gate

`fvm dart analyze --fatal-infos` and `fvm dart format` on the one changed file
(a doc comment) — clean. The full gate ran at round 609, one commit earlier.

## Not fixed

Nothing in B-225.

## Links

Lead `../backlog/B-225-what-the-connection-total-does-not-see.md` — closed.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` — `applied: [..., 610]`.
