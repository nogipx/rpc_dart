---
round: 724
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-17
bench: P-238 — reused
commit: yes
release: none
---

# Round 724 — a deaf reader's requests are bounded

## Target

Round 723's open half. While the deaf reader holds the handler at one
window, it keeps sending requests. Round 720 left the h2 responder
transport's own request window charging payload alone and relied on the core
budget. Whether that budget sees a BIDI request queue, and not only a
client-stream sink, was unmeasured.

## Hypothesis

Bidi requests bypass the core budget. Then the only bound is the transport's
4 MiB of payload, about 520k eight-byte requests held per stream.

## Before

P-238 in `deaf` mode with reading resumed after the sends.
`produced` counts the requests the handler consumed after the resume, which
is how many the server was holding.

```
  requests sent    held, then        outcome
  400000           152508            grpc-status 8
  1000000          66 (no resume)    stream done, refused while deaf
```

## Mechanism

The hypothesis does not hold. The bidi request queue is charged to the core
budget like a client-stream sink, at round 719's weight (bytes plus 128), so
it is refused at about 16 MiB of weight. That is 152k requests, and the
process RSS grew 30 MiB.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. Bench sensitivity is round 719's: with the per-message charge
at 0 the same queue passes the connection total unrefused
(`tiny_messages_are_weighed_test`).

## The verdict questions

1. Yes: the request count is the only variable.
2. Yes: refused at 152508 of 400000 against the 520k a payload-only bound
   would allow.
3. Counted in the server's handler.
4. Not zero.
5. No fix, so no witness.
6. n/a.
7. CLEAN.
8. None.
A1. The raw client has no policy; the server uses the default.
A2. Volume.
L1. The refusal is the core budget's: 152k matches 16 MiB at 110 bytes per
    message. The transport window would need 520k.

## Gate

No library change.

## Not fixed

A refused deaf reader gets no `grpc-status`: the trailer queues behind the
paused DATA and the reset drops it. The peer chose not to read, so this is
accepted.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [..., 724]`.
Bench `../probes/P-238-a-deaf-reader-against-an-h2-bidi-handler.md`.
