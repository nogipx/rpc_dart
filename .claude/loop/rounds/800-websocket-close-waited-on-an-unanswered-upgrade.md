---
round: 800
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-28
bench: P-291 — new
commit: yes
severity: S1
release: changelog
---

# Round 800 — websocket close waited on an unanswered upgrade

## Target

B-277, rank 1 of the open leads and an S1: the conformance matrix's I-5 row
("the caller closes after its peer was silent") failed on websocket alone.
First round under the new regime, so the lead the matrix filed comes before
any lens. The leads awaiting the owner were not taken (`## Not fixed`).

## Hypothesis

`RpcWebSocketCallerTransport.close()` never returns while the peer has not
answered the upgrade, on both paths that hand the transport an unopened
channel: the README's given channel, and a `reconnectFactory`.

## Before

```
given      STILL PENDING at the 20 s cap
reconnect  STILL PENDING at the 20 s cap
answered   returned after 7 ms            <- control
matrix: websocket | close after peer silent   did not close within 3 s
        channel, http, http2, isolate          closed
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r800_close_before_the_handshake.dart`.

## Mechanism

`RpcWebSocketChannel.close()` awaited `_ws.sink.close()`, and a
`WebSocketChannel` that is still connecting closes its sink only once the
upgrade is answered. A silent peer never answers.

## After

```
given      returned after 5 ms
reconnect  returned after 0 ms
answered   returned after 6 ms            <- control, unchanged
```

`RpcWebSocketChannel` records when `ready` completes and awaits the sink's
close only then. Before it the close is started and not awaited, so the
socket still closes if the upgrade ever completes. Both close paths (plain,
and with a protocol or oversize code) go through it.

## Canary

With the readiness check switched off in place, both witnesses fail:

```
close_before_the_handshake_test: Expected: 'closed'  Actual: 'STILL PENDING at 2 s'
I-5 websocket | close after peer silent: the websocket caller transport did
not close within 3 s
```

Restored: both green, the I-5 file 98 passed.

## The verdict questions

1. Yes: `answered` differs from `given` only in the peer answering the
   upgrade.
2. Yes: 7 ms against still pending at 20 s.
3. On the caller: the future `close()` returns, timed around it.
4. n/a, not a zero.
5. Quoted in `## Canary`.
6. One mechanism, two ways in (given channel, reconnect factory): a witness
   for each, both failing under the one switch.
7. From the table.
8. The leads awaiting the owner, set aside by their status, not taken. The
   lens's own detector greps opens only; it is extended below rather than
   trusted.
9. A close that awaits something the open was still waiting on inherits the
   open's unbounded wait; the close needs its own answer for "never opened".
   Price: a shutdown that never returns, found only by the matrix after two
   rounds (755, 773) had bounded every open. Written into RPC-28's detector,
   not as a lesson: it is a place to look, not a way to measure.
10. Every sibling line is the same I-5 cell run on that member, or a stated
    structure (wasm). S1: a close that never returns, measured.
A1. n/a: the peer is a raw socket with no policy.
A2. Latency: a real socket that stays silent.
L1. n/a: no refusal involved.

## Gate

`melos run analyze`, `format:check`, `license:check`, `test:unit` (14
suites, the matrix included): green.

## Siblings

- channel: clean — the same I-5 cell, close after a silent peer, passes
  (a channel has no upgrade to wait on)
- http: clean — the same I-5 cell passes
- http2: clean — the same I-5 cell passes; its close is bounded by its 2 s
  graceful budget
- isolate: clean — the same I-5 cell passes (the worker in silent mode)
- websocket: fixed here
- wasm: n/a — outside the workspace; its bridge has no upgrade stage, and
  `test:wasm` covers its close

## Not fixed

The pending connect itself is not aborted: `WebSocketChannel.connect` gives
no handle to cancel it, so a socket a silent peer holds lives until the peer
drops it. `connect()` already bounds that with its 30 s default (round 755);
the given and factory forms are the caller's channel.

Not touched, awaiting the owner: B-272 to B-276, B-280, B-282. None of
their paths is the file this round changed.

## Links

Lens `../lenses/RPC-28-a-connect-timeout-that-ends-a-stage-early.md`.
New bench `../probes/P-291-close-before-the-handshake.md`. Lead
`../backlog/B-277-websocket-close-never-completes-against-a-silent-peer.md`,
closed. Round 755 set the open's bound; this is the close's.
