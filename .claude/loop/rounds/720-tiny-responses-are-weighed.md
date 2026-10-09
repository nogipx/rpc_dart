---
round: 720
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-17
bench: P-236 — new
commit: yes
release: changelog
severity: S2
---

# Round 720 — tiny responses are weighed

> **Retracted by round 729.** The weighing refused an honest reader slightly
> slower than its server (stopped at 34002 of 300000), a bound the server is
> never told of (L-20). The code is back to payload alone.

## Target

The mirror of round 719. 719 weighed what a queued REQUEST message retains on
the h2 responder. The h2 CALLER bounds a response its consumer stopped
reading by the same window, and charges payload bytes alone.

## Hypothesis

A server streaming tiny responses into a paused caller gets about
`window / 9` messages accepted, while each retains more than 200 bytes.

## Before

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r720_tiny_responses_to_a_paused_caller.dart`.
Server-stream to a caller that takes 3 items and pauses. `produced` counts at
the server's generator; RSS covers both sides in one process.

```
  arm                               produced   rssDelta
  1 KiB responses, paused (control)     4245    +36 MiB
  empty responses, paused             472002   +108 MiB
```

## Mechanism

`_fcOnDelivered` and `_fcMetered` charged `payload.length`, the framed
message, 9 bytes here. The 4 MiB window therefore admitted 472k messages,
at about 229 bytes retained each.

## Fix

`unconsumedWeightOf` in `rpc_http2_common.dart` (internal): payload plus 128.
The caller charges and discharges with it. The README states the weight.

## After

```
  empty responses, paused              36002    +52 MiB
  empty responses, reading            200000 of 200000 received
```

## Canary

The 128 removed: `tiny_responses_are_weighed_test` fails with
"Expected: a value less than <100000>, Actual: <300000>".

## The verdict questions

1. Yes. One function changed. The 1 KiB arm and the reading arm are the
   controls.
2. Yes: 472002 against 36002.
3. At the server's generator, which stops once the caller resets the stream.
4. Not zero.
5. Quoted.
6. One mechanism.
7. A trade: an honest server streaming tiny messages to a stalled consumer is
   refused at about 30k un-consumed instead of about 470k. Websocket's depth
   is 8192.
8. None.
A1. Caller and server use separate default policies.
A2. Volume.
L1. The stop comes from the caller's window reset. The server has no
    response-side bound that fires earlier.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`; rpc_dart_http2 304.

## Not fixed

The h2 responder's transport-level request window still charges payload
alone. The core budget weighs the same messages first since round 719, so
nothing is retained past it.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [..., 720]`.
New bench `../probes/P-236-tiny-responses-against-the-caller-window.md`.
P-234's `commit:` repointed at `e8341816`: the squash of 717-718 replaced
`2a4f712f`.
