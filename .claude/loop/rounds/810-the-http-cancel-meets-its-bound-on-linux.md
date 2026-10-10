---
round: 810
verdict: CLEAN
packages: [rpc_dart_conformance]
lens: RPC-14
bench: P-295 — reused
commit: yes
severity: S3
release: none
---

# Round 810 — the http cancel meets its bound on Linux

## Target

B-284, decided by the owner after round 809: measure the http close latency
on Linux before touching I-6's bound; if it holds there, the http cells come
off KNOWN FAILING where it holds. The owner confirmed Docker is available.

## Hypothesis

The ~2.1 s between a client's close and a Dart server seeing it is a macOS
property; on Linux a cancel over http reaches the handler inside I-6's 1 s.

## Before

```
macOS (round 809): close seen 2101 ms after it (Socket), 2097 ms (RawSocket)
I-6 http cells: KNOWN FAILING everywhere (~4.2 s through the proxy)
I-5 http callerCancels cells: KNOWN FAILING everywhere
```

## Mechanism

n/a (CLEAN): the delay is below rpc_dart.

## After

```
Linux, docker dart:3.10.1 (linux/arm64), P-295:
  close, Socket server        5 ms, 4 ms
  destroy, Socket server      4 ms
  close, RawSocket server     1 ms
Linux, the workspace copied into the container, I-6 + I-5:
  --run-skipped -n 'http | '  27 passed (every http cell, at 1 s and 2 s)
  with the marks made macOS-only, no flag: +133 ~29 (macOS: +123 ~39)
```

The marks in `i6_cancel_reaches_responder_test.dart` and
`i5_resources_return_test.dart` now apply on macOS only, and say so (L-17:
a skip states its condition).

## Canary

The control is the platform: the same probe, Dart version and client
process give 2.1 s on macOS and under 5 ms on Linux; the same http cells
fail at 1 s on macOS and pass on Linux.

## The verdict questions

1. One thing differs, the OS.
2. Yes: 2101 ms against 5 ms.
3. At the server's socket (`onDone` / `readClosed`), the client's close
   time reported by the client process.
4. n/a.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control; the macOS delay is recorded, not fixed.
8. B-284's text was re-measured, not trusted.
9. none.
10. No library code changed.
A1. n/a. A2. Latency: introduced by the OS, measured on both.
L1. n/a.

## Gate

The conformance package: macOS +510 ~152 green; Linux I-6 + I-5 +133 ~29
green. `analyze` of the package after `format`. No library code changed
since 2fee1b9d.

## Siblings

No library code changed.

## Not fixed

- On macOS an http cancel still reaches the handler ~2.1 s late (a
  development machine, not where servers usually run). Why macOS delays a
  peer's close is not measured.

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md`. Bench
`../probes/P-295-when-a-closed-connection-reaches-the-server.md`. Lead
`../backlog/B-284-the-http-cancel-arrives-after-the-i6-bound.md`, closed.
