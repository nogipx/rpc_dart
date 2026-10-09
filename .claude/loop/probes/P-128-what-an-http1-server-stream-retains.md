---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b98_unbounded_response.dart
round: 489
commit: 9b6a5357
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
---

# P-128 — what an HTTP/1.1 server stream retains

## Why it exists

HTTP/1.1 cannot flush a response before the end, so a server stream's whole
output is resident until the handler finishes. The bench asks two things,
because the fix rests on the second: how much does the server retain, and can
the caller receive any of it once past its own ceiling?

## The harness

An 8 KiB-per-item server stream against a 64 KiB `maxMessageLengthBytes` on BOTH
sides, three production scales, plus a control that fits. Peak RSS sampled every
20 ms from `ProcessInfo.currentRss`, and the caller's delivered item count.

**Run LARGEST FIRST.** RSS never returns, so in ascending order every arm after
the first reads `+0` whatever happens, and the first arm's number is warm-up
plus retention with no way to separate them. Largest-first puts the whole
measurement in the arm that pays the warm-up, and the ablation is then a
like-for-like comparison of that one number.

## The numbers (round 489)

```
ascending, before the fix
  512 KiB produced    peak RSS  +8720 KiB   received 0  status=8
  2048 KiB produced   peak RSS +12608 KiB   received 0  status=8
  8192 KiB produced   peak RSS +40208 KiB   received 0  status=8
  32 KiB (control)    peak RSS     +0 KiB   received 4  ok

largest first, one variable
  8192 KiB, no cap    peak RSS +57664 KiB
  8192 KiB, capped    peak RSS +11456 KiB
```

## Measures

Peak RSS delta over the call, and the number of items the CALLER received. The
second is what makes the first actionable: `received 0` in every over-limit arm
means the retained bytes could never have been delivered.

## Control

`32 KiB produced` against the same 64 KiB ceiling — a stream that fits, reading
`+0 KiB` and 4 items delivered, before and after. And the ablation above, which
is the one that separates retention from warm-up.

RSS is a blunt instrument and both ends live in this process, so the ~11 MiB
floor is the harness. What the bench establishes is the SHAPE: before, the
number tracks what the handler produced; after, it does not.

## What it establishes, and what it does not

Establishes: the server retained in proportion to production, for bytes the
caller then refused.

Does NOT measure the handler's own cost. It keeps running after the stream is
ended — this transport has no reset — so what is bounded is what is RETAINED,
not what is computed.

## Reading

rpc_dart_http — peak RSS against production at three scales, plus the caller's
delivered item count, which is what turns the cost into a defect (`received 0`
in every over-limit arm). **Run it LARGEST FIRST**: RSS never returns, so in
ascending order every arm after the first reads `+0` whatever happens and the
first mixes warm-up with retention
