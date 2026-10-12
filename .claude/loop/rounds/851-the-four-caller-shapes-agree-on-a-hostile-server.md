---
round: 851
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: P-317 — reused
commit: yes
release: none
---

# Round 851 — the four caller shapes agree on a hostile server

## Target

P-317 (round 848) measured unary and server stream only. RPC-25, ranked
first in the curate pass: the four caller shapes are four copies of one
contract, and the client stream shares unary's one-response rule.

## Hypothesis

The client stream and bidi end every hostile response the way unary and the
server stream do (one-response shapes refuse no message and two messages).
Fails if one shape accepts what its sibling refuses.

## Before

```
scenario                 unary      server     client     bidi
no message, OK           ERROR 13   OK []      ERROR 13   OK []
two messages, OK         ERROR 13   OK [a,b]   ERROR 13   OK [a,b]
status 99 / x / -1       ERROR 2    ERROR 2    ERROR 2    ERROR 2
trailer without status   ERROR 13   ERROR 13   ERROR 13   ERROR 13
end on DATA, no status   ERROR 13   ERROR 13   ERROR 13   ERROR 13
trailers-only OK         ERROR 13   OK []      ERROR 13   OK []
the other eight rows     the same outcome on all four
```

The control is P-317's valid row: `OK value=a` / `OK items=[a]` on all four.

## Mechanism

None found: the one-response shapes share `RpcCallerTrailer.noPayload` and
the too-many-messages refusal, and all four read the status through
`RpcCallerTrailer.statusOf`.

## After

n/a.

## Canary

n/a — no fix.

## Gate

No library change.

## Siblings

—

## Not fixed

Nothing found.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`.
Negative `../checked/C-86-the-four-caller-shapes-agree-on-a-hostile-server.md`.
