---
round: 618
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-220 — new
budget: probes 3/5, canaries 0/5
commit: yes
release: none
---

# Round 618 — a hundred nanoseconds against four microseconds

## Target

B-213: the rate limiter resolves its counters on every message of a metered
stream, and a per-call cache would have to survive an eviction. The lead
asked for a throughput arm first. If the difference does not show against
run-to-run spread, it closes as a non-cost.

## Hypothesis

Per-message resolution is a visible share of a streamed message's cost.

## Before

```
limiter alone, ns per message
  no limiter 53-118   static 242-294   dynamic 367-392   dynamic+global 430-525

one client-stream call, ns per message, 11 runs
  no limiter        min 3476  median 4366  max 13510
  dynamic + global  min 4319  median 4733  max 7451
```

## Control

The no-limiter arm of each bench.

## Mechanism

What a cache could remove is the re-resolution itself: the method-key string,
the key extractor and the LRU touch, measured as dynamic minus static, about
120 ns per message. That is under 3 % of a 4.4 us streamed message. The
end-to-end spread is 900 ns between minimum and median on the unlimited arm
alone. The whole limiter, counters included, moves the median by about 370 ns,
also inside that spread. The eviction case the cache would have to handle is
pinned already (`audit_rate_limiter_eviction_test.dart`), and keeping it is
worth more than the 120 ns.

## After

n/a — no change.

## Canary

n/a — no fix.

## Gate

Not run: no change to `lib/` or `test/` in this round. Round 617's gate ran on
the commit before it.

## Not fixed

The lead's smaller item, a construction-time warning when `perMethod` is looser
than `global`, has not been load-bearing since round 542 made `global` a ceiling,
and it needs a rule for comparing a token bucket's burst with a sliding window's
rate. Left as a design note in the lead, not a defect.

## Links

Lead `../backlog/B-213-the-rate-limiter-resolves-its-counters-per-message.md` — closed.
Bench `../probes/P-220-what-the-limiter-costs-a-message.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 618]`.
