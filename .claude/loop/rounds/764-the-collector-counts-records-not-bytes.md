---
round: 764
verdict: DEFERRED
packages: [rpc_dart_log]
lens: RPC-27
bench: P-265 — new
commit: yes
release: none
---

# Round 764 — the collector counts records not bytes

## Target

`LogCollectorMcpBuffer.maxRecords`, round 763's opening target: the buffer
is bounded by record count, and what a record weighs is bounded only by the
transport's message ceiling. Proposed to the owner as a candidate lens, "a
bound counted in the wrong unit"; this round is its first measurement.
Became lens RPC-27 after round 765.

## Hypothesis

The buffer's memory grows with record size at a fixed count, so the default
5000 holds gigabytes for large records.

## Before

P-265, 1000 records through a real `LogCollectorOutput`:

```
  big    256 KiB records   held 1000 of 1000   rss +343 / +358 MiB
  small  100 B records     held 1000 of 1000   rss +10 / +10 MiB
```

## Mechanism

`addRecord` evicts on `_records.length > maxRecords` only. Nothing reads the
size of a record. At 256 KiB a full default buffer is about 1.7 GiB.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. The arms differ in message size only.
2. Yes: +343 MiB against +10 MiB.
3. In the collector's process; the sender reuses one string.
4. n/a.
5. n/a.
6. n/a.
7. DEFERRED for an owner decision: a byte budget changes the documented
   "last N records" of two public classes, and the peers are the operator's
   own apps (loopback by default), which puts this under the severity bar's
   question rather than a fix's.
8. The sender's `bufferSize` was not measured; it is named in B-271 as
   unmeasured, not ruled out.
9. None.
A1. One process; the sender is `LogCollectorOutput` with defaults, the
    victim `LogCollectorMcpBuffer` with defaults.
A2. Volume.
L1. No refusal; the bound never fires because it counts records.

## Gate

n/a — no code change.

## Not fixed

B-271, awaiting the owner.

## Links

Probe `../probes/P-265-what-the-log-buffer-holds-when-records-are-large.md`.
Lead `../backlog/B-271-the-log-buffers-are-bounded-in-records-not-bytes.md`.
Round `763-the-collector-assembled-what-the-transport-cuts.md`.
