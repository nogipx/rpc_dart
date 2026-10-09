---
round: 765
verdict: FIXED
packages: [rpc_dart_log]
lens: RPC-17
bench: P-265 — reused
commit: yes
release: changelog
---

# Round 765 — the log buffers are bounded in bytes

## Target

B-271, by the owner's decision: a byte budget beside the record count on
both log buffers, `LogCollectorMcpBuffer` (collector) and
`LogCollectorOutput` (application). The class: these are the two record
buffers in `rpc_dart_log`; the scope, trace-id and unique-error indexes are
bounded by entry count and hold keys or at most 5 records.

## Hypothesis

With `maxBytes` the collector's buffer stops at the budget whatever a record
weighs, and the small-record behaviour is unchanged.

## Before

P-265, 1000 records sent, from round 764 and again on this sha's parent:

```
  big    256 KiB records   held 1000 of 1000   rss +343 / +358 / +238 MiB
  small  100 B records     held 1000 of 1000   rss +10 MiB
```

## Mechanism

Each buffer now charges a record `approxJsonBytes` of its JSON form (string
code units plus 8 per scalar) and evicts the oldest while over the count OR
the bytes, keeping the newest. Defaults: 64 MiB on the collector
(`maxBytes`, `bufferBytes` in `LogCollectorMcpServer.run`), 8 MiB in the app
(`bufferBytes`). The output keeps one total across its two queues and gives
a record's bytes back on its ack. The stats line's "buffer full" now reads
any eviction, not only a count one.

## After

P-265 after the fix (waits for all 1000 received, not held):

```
  big    256 KiB records   held 255 of 1000   rss +164 / +161 MiB
  small  100 B records     held 1000 of 1000  rss +10 MiB
```

255 x 256 KiB is the 64 MiB budget. RSS also carries the garbage of the
1000 decoded messages; the held count is the witness.

## Canary

`packages/core/rpc_dart_log/test/the_record_buffers_are_bounded_in_bytes_test.dart`,
5 tests, 3 of 3 runs green. Three halves, three canaries:

```
  buffer eviction off   Expected: a value less than <5>  Actual: <20>
                        Expected: <1>  Actual: <2>
  output trim off       Expected: a value less than <5>  Actual: <20>
  ack refund off        Expected: <0>  Actual: <2940>
```

## The verdict questions

1. The arms differ in message size only; before and after differ in the fix.
2. Yes: 1000 held against 255.
3. `recordCount` of the collector's buffer, in its process.
4. n/a.
5. Yes, the three messages above.
6. Three halves, three canaries.
7. FIXED from the held counts.
8. Nothing dismissed.
9. None.
A1. One process; `LogCollectorOutput` and `LogCollectorMcpBuffer` with
    defaults.
A2. Volume.
L1. The eviction under test is the byte budget: the count (5000) is never
    reached by 1000 records.

## Gate

`melos run analyze`, `format:check`, `check:skills`, `test:unit` green.

## Not fixed

Nothing.

## Links

Lead `../backlog/B-271-the-log-buffers-are-bounded-in-records-not-bytes.md`.
Probe `../probes/P-265-what-the-log-buffer-holds-when-records-are-large.md`.
Round `764-the-collector-counts-records-not-bytes.md`.
