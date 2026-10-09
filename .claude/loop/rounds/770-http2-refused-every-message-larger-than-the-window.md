---
round: 770
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-08
bench: P-270 — new
commit: yes
release: changelog
---

# Round 770 — http2 refused every message larger than the window

## Target

Rounds 768-769 fixed messages larger than the window on the channel core.
The same messages across every real transport: websocket, http2, isolate.

## Hypothesis

Each transport carries any message up to the 16 MiB limit under its
default policy.

## Before

P-270, 3 x 7 MB:

```
  websocket  feed 3/3 done    paused 3/3 done    upload 3/3
  isolate    feed 3/3 done    paused 3/3 done    upload 3/3
  http2      feed 0/3  RpcStatusException(8): Response exceeds the
                       un-consumed window (7000013 > 4194304 bytes)
             paused 0/3  (same)
             upload     Request exceeds the un-consumed window
                        (7000013 > 4194304 bytes)
```

## Mechanism

HTTP/2's own un-consumed bound (`_fcOnDelivered`, caller and responder,
threshold `unconsumedWindowFor` = the 4 MiB stream window) charged the
message that had just arrived before checking. A message is delivered
whole, so any message over 4 MiB was refused on arrival, in both
directions, however fast the peer read. Fix: refuse when what was ALREADY
waiting exceeds the window. A consumer that falls behind is still refused
one message later (C-19, by design).

## After

```
  http2  7 MB:  feed 3/3 done   upload 3/3   paused: refused on the 3rd
                (14000026 waiting > 4 MiB: C-19's slow-consumer refusal)
  15 MB, all three transports: feed, paused, upload 3/3 done
```

## Canary

`packages/transport/rpc_dart_http2/test/a_message_larger_than_the_window_is_not_refused_test.dart`,
3 of 3 green. One half at a time:

```
  caller half off     RpcStatusException(8): Response exceeds the un-consumed
                      window (6000013 > 4194304 bytes)
  responder half off  RpcStatusException(8): Request exceeds the un-consumed
                      window (6000013 > 4194304 bytes)
```

## The verdict questions

1. The rows differ in transport only.
2. Yes: http2 0/3 against 3/3 on the others.
3. At the caller and in the server's answer.
4. n/a.
5. Yes, above.
6. Two halves, two canaries.
7. FIXED from the counts.
8. The paused 7 MB row on http2 still fails: ruled by C-19 (the owner
   accepted refusal of a consumer that falls behind), checked by its
   number — two messages waiting, 14 MB over a 4 MiB window.
9. None.
A1. Default policy on both ends.
A2. Volume.
L1. The refusal named the un-consumed window, the bound under test.

## Gate

`melos run analyze`, `format:check`, `test:unit` green; rpc_dart_http2
310 + 2. README says what the bound counts.

## Not fixed

Nothing in this class. HTTP/1.1 (`rpc_dart_http`) was not in the probe:
its bodies are bounded separately (round 610's sweep).

## Links

Probe `../probes/P-270-large-messages-across-the-transports.md`.
Rounds `768-a-message-larger-than-the-window-stalled-the-stream.md`,
`769-the-connection-total-refused-an-honest-overshoot.md`.
Negative `../checked/C-19-http2-refuses-a-slow-consumer.md`.
