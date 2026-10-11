---
round: 826
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-28
bench: none — one probe, below; a CLEAN with a control
commit: yes
release: none
---

# Round 826 — a silent peer does not hold the websocket stop

## Target

Network-audit KV-WS-06, the server's half: round 800 fixed a caller whose
close waited on a peer that never answered, and the journal has no server
record for the same shape (`find 'websocket server close frame never
answered'`, `--path rpc_websocket_server.dart`).

## Hypothesis

`stop()` closes each endpoint, and closing a WebSocket waits for the peer's
close frame, so one peer that stopped reading holds the shutdown for good.

## Before

```
r826_stop_silent_peer.dart 0 (control, one honest client): stop 9 ms
```

## Mechanism

n/a (CLEAN).

## After

```
  silent peers   stop()
  1              returned, 7 ms
  5              returned, 19 ms
```

## Canary

n/a; the silent peers read the 101 and are paused before `stop()`, and the
honest client is connected through the same server, so the endpoints exist
when it runs.

## The verdict questions

1. Only the number of silent peers differs.
2. No difference: the result is CLEAN.
3. At the server: when `stop()` returned (60 s cap).
4. Up to five peers; the cap would have shown a hang.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. Defaults. A2. Latency. L1. n/a.

## Gate

No code changed; the probe is outside the tree.

## Siblings

No code changed. The caller half is round 800.

## Not fixed

- `stop(drainTimeout)` with silent peers not measured.

## Links

Lens `../lenses/RPC-28-a-connect-timeout-that-ends-a-stage-early.md`.
Negative `../checked/C-79-a-silent-websocket-peer-does-not-hold-stop.md`.
