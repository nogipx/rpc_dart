---
round: 820
verdict: CLEAN
packages: [rpc_dart_http]
lens: RPC-17
bench: P-303 — new
commit: yes
severity: S3
release: none
---

# Round 820 — a pipelined header block waits in the kernel

## Target

Attacking round 811's own fix. `_WatchedSocket._admit` stops scanning at
the end of a header block and starts again only at `responseWritten`, so a
request pipelined behind a slow one is not counted against the byte bound
or the header deadline while the first request runs.

## Hypothesis

dart:io reads and holds the pipelined request's header block while the
first request runs, so a peer holds memory per connection past the bound
for as long as any slow method runs.

## Before

```
P-303 first arm (round 811's case), 5 connections, 20000 KiB offered:
  closed 5, server RSS 9 MiB
```

## Mechanism

n/a (CLEAN). dart:io does not read a connection while a request on it is in
flight, so the pipelined bytes stay in the kernel's socket buffer.

## After

```
  arm         closed   accepted by the kernel   server RSS
  first       5        4576 KiB                 9 MiB
  pipelined   0        10595 KiB                11 MiB
```

## Canary

The first measurement was wrong, and the control is what caught it. One
process held attacker and server: +373 MiB for 200 pipelined connections
against nothing for `first`. The two arms differed in more than the
pipelining, because the `first` connections were closed, which freed the
attacker's own unflushed writes. Split into two processes, the server's own
RSS does not move. (Measurement discipline 5: which side the number was
taken on.)

## The verdict questions

1. In the two-process bench only the pipelining differs.
2. No: the server's RSS is the same in both arms.
3. In the server process, its own `ProcessInfo.currentRss`.
4. 20 MB offered per connection, read over 8 s.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. Defaults. A2. Volume; the hold is the slow method's.
L1. n/a.

## Gate

No code changed; the probes are outside the tree (`.dart_tool/probe`).

## Siblings

No code changed. The websocket server's header block is B-287.

## Not fixed

none.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md`. Bench
`../probes/P-303-a-pipelined-request-behind-a-slow-one.md`. Negative
`../checked/C-76-a-pipelined-header-block-is-not-read-while-the-first-request-runs.md`.
