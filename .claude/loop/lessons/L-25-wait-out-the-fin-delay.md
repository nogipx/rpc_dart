---
round: 842 (paid), 839 (paid without knowing it)
class: bench
cost: round 839 recorded a false "dart:io trap" in P-310 and in its own Not fixed, and rewrote a witness around it; round 842 spent six probe runs and three client kinds (a Dart process, nc -z, nc with stdin closed) on REFUSED readings that were the delay itself
paths: [packages/transport/*/lib/**]
commit: 4c753983
status: active
---

# L-25 — wait out the FIN delay before reading a peer's close

## The rule

On this macOS a peer's close reaches the server about 2.1 s after it happens
(P-295): the kernel shows both ends ESTABLISHED until then, whoever closed. A
probe that reads the server's state sooner sees a peer that has not left, and
reads it as the server holding the connection or as the client failing to
close. Settle 2.5 s or more, or poll for the close, before any reading that
depends on the server having seen the peer go.

## What it cost

Round 839 read socket states 500 ms after a Dart client's `destroy()`, saw
ESTABLISHED on both ends and blamed dart:io. Round 842 saw the same with nc
and with a plain `ServerSocket`, polled, and the close arrived at 2.5 s.
