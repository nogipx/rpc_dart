---
round: 729
verdict: RETRACTED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-15
bench: P-235 — reused
commit: yes
release: changelog
---

# Round 729 — the weighing failed honest peers

## Target

Rounds 719 and 720, re-measured against the rule they should have been
checked against before they were written. That rule is L-20: a receiver bound
the sender is not told of fails honest peers. On HTTP/2 neither per-stream
bound is visible to the sender. Round 715 (owner's decision, B-261) removed
the depth bound for exactly that reason, and 719/720 brought a depth bound
back as a byte charge.

## Hypothesis

An honest sender of small messages to a consumer only slightly slower than
it, pausing 1 ms every 20 messages as round 715's witness does, is now
refused where before 719/720 it was not.

## Before

P-235 (`r719_..._byte_bound.dart`, new `slow` arm) and P-236
(`r720_..._paused_caller.dart`, new `slow` arm):

```
  honest arm                                     before 719/720   with them
  upload 300000 x 'x', handler 1 ms per 20       ok               status 8
  server stream 300000 x '', reader 1 ms per 20  produced 300000  stopped at 34002, refused
```

## Mechanism

Both rounds charged the per-message overhead to the PER-STREAM bound: the
core budget's `streamBytes` (719) and the h2 caller's un-consumed window
(720). A fast sender fills that bound with backlog alone, about 30k (caller)
or 150k (responder) tiny messages, without doing anything wrong.

## Fix

- **Round 720 is retracted.** The h2 caller is back to charging payload
  alone, byte for byte as before it, README included. What it bounded was a
  hostile SERVER filling one call the client opened, about 108 MiB per call,
  a lower-severity case than failing honest result sets.
- **Round 719 is narrowed.** The 128-byte overhead is charged to the
  connection total only (`take(..., overhead:)`). The per-stream check is
  back to payload bytes. The state keeps the overhead in its own counters, so
  the release matches the charge. Policy, marker doc and skill table say
  "per stream bytes; connection total bytes plus 128".

## After

```
  upload 300000, slow handler                     ok
  8 parked streams x 500000 (round 719's attack)  refused, rssDelta -31 MiB
  server stream 300000, slow reader               all produced
```

Round 715's and round 719's witnesses still pass.

## Canary

Two halves, two canaries:

- The overhead put back into the per-stream check:
  `a slightly slow handler receives every tiny upload` fails with "Stream 1
  buffered too much without consuming it".
- Round 720's weighing put back into the caller: `a slightly slow reader
  receives every tiny response` fails with "Response exceeds the un-consumed
  window (4194392 > 4194304 bytes)".

## The verdict questions

1. Yes. The honest arms differ from round 715's witness only in count.
2. Yes: ok against status 8, 300000 against 34002.
3. At the handler, and at the server's generator.
4. n/a.
5. Quoted, both.
6. Two halves, two canaries.
7. RETRACTED for 720. For 719, a narrowing that keeps its measured gain
   (-31 MiB on the multi-stream attack).
8. Yes, but it is already written: L-20. This round is the price of not
   reading it before rounds 719 and 720, which reported FIXED with a green
   gate. Every honest-peer witness in the suite was below the new threshold.
A1. Server and caller policies are separate objects.
A2. Volume, with latency introduced by the consumer's pauses.
L1. Each refusal names the bound that fired.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`. Suites: core 2099,
rpc_dart_http2 305.

## Not fixed

The h2 caller is again exposed to a hostile server filling one call it
opened: about 470k tiny messages, 108 MiB per call. It is bounded per call,
and the client chooses its calls.

## Links

Lesson `../lessons/L-20-a-limit-the-sender-cannot-see.md` — the rule broken.
Rounds `719-tiny-messages-are-weighed.md` (narrowed) and
`720-tiny-responses-are-weighed.md` (retracted). Lens
`../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 729]`.
