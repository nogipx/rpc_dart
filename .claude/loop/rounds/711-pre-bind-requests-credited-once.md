---
round: 711
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: none — `.dart_tool/probe/audit_core_ep/credit_probe2.dart` (client stream, depth and stall point as arguments)
commit: yes
release: changelog
---

# Round 711 — pre-bind requests credited once

## Target

B-259, from the six-way audit the owner asked for after round 710: rounds 709
and 710 left two defects in their own mechanism.

## Hypothesis

A request frame that arrives before the client-stream handler is bound is
credited on arrival (the stream is not deferred yet), and credited again by
`_pipelineFedRequestStream` when the handler takes it. The sender runs one
message ahead of the depth.

## Before

```
depth 64, stall at 31     RESOURCE_EXHAUSTED
depth 64, stall at 95     RESOURCE_EXHAUSTED
depth 64, stall at 64     1000/1000      (control)
depth 8192, stall 4095    RESOURCE_EXHAUSTED
```

The failing stall points are the grant flushes (half the depth) minus the
first message, as the hypothesis predicts.

## Mechanism

As hypothesised. Skipping the second credit alone is not enough: the peer was
told the pre-bind messages are consumed while they still sit in the queue, so
the depth bound must allow for them until the handler takes them.

## Fix

`_pipelineFedRequestStream` counts the payload messages queued before the bind
(`markPreCredited`); the handler's first takes spend that count instead of
crediting (`takePreCredited`), and `pushRequest` subtracts the outstanding
count from the depth it checks.

Second defect, same files: `advertisedWindowBytes` fell to 1 when an explicit
`maxBufferedBytes` left no room for a maximal message on top of the window, so
a hardening value like 8 MiB made every stream stop-and-wait. It now falls back
to half the buffer; 8 MiB keeps the 4 MiB window.

## After

```
depth 64, stall at 1/31/95   1000/1000
depth 8192, stall 4095       20000/20000   (sender stopped at 8193)
```

## Canary

`markPreCredited` forced to 0: the stall-at-31 and stall-at-95 tests fail.

## The verdict questions

1. Yes. 2. Yes, the upload direction round 709 named. 3. Yes. 4. Not zero.
5. Quoted. 6. Two defects, each with its own test. 7. Not a trade.
8. One unit expectation changed (`tight` window 1 -> 502), stated above.

## Gate

`analyze`, `format:check`, `check:skills`, `test:unit`, `test:wasm`;
`test:web` once failed on a Chrome cold start, both web-worker files then
passed alone.

## Not fixed

B-262 (connection window alone carries no message credit) and B-261 (h2 has no
message credit at all), both filed for the owner.

## Links

Lead `../backlog/B-259-pre-bind-requests-are-credited-twice.md` closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` -- `applied: [..., 711]`.
