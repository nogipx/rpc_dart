---
round: 739
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-03
bench: P-228 — reused
commit: yes
release: none
---

# Round 739 — stream ids still hold across reconnects

## Target

RPC-03, last applied in round 661. Since then 14 commits touched the h2
caller's reconnect-facing code: the proxy path, `close()` aborting calls at
once, and the TLS and ALPN checks. Its three benches are cheap to re-run, so
they were re-run rather than read.

## Hypothesis

A change since round 661 lets a stream id come back after a reconnect, or a
stale id reach the new socket.

## Before

```
P-228 (lim_ids.dart)
  A1 wrap, no long-lived stream   ok 12/12, cursor wraps to 1, 3, 5 ...
  A2 wrap, long-lived stream      ok 12/12
  B WITNESS near top              conn1 [.., 2147483647, 1, 3]  conn2 [5 .. 13]  OVERLAP []
  B CONTROL low                   conn1 [1003..1011]  conn2 [1013..1021]       OVERLAP []
P-115 (does_an_id_come_back_after_a_reconnect.dart)
  websocket / http2 / proxy       before=1 after=3, no collision
P-161 (b131_peer_id_reuse.dart)
  peer id, peer REUSES it         DELIVERED  1
  peer id, not reused             dropped    0
  own id, space resumed           dropped    0
  CONTROL no reconnect            DELIVERED  1
```

## Mechanism

None. Every row matches its bench's recorded post-fix state. P-161's first row
is the limitation that bench records: a guard keyed on set membership cannot
see a number the peer reused.

## After

n/a.

## Canary

n/a — no fix. Each bench carries its own control row (P-228 B CONTROL, P-161
row 4).

## The verdict questions

1. Yes: the benches' own controls.
2. Yes: each control differs from its case as recorded.
3. Ids are read at the transport; P-161 counts frames at the far end.
4. Not zero.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change.

## Not fixed

Nothing new.

## Links

Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` — `applied: [..., 739]`.
Benches `../probes/P-228-stream-ids-across-the-wrap.md`,
`../probes/P-115-does-an-id-come-back-after-a-reconnect.md`,
`../probes/P-161-does-a-stale-id-reach-the-new-socket.md`.
