---
round: 756
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-18
bench: P-261 — new
commit: yes
release: changelog
---

# Round 756 — the client had no message ceiling

## Target

RPC-18, the dependency buffering below every limit. Round 611 bounded an
unfinished WebSocket message on the SERVER (`rpcWebSocketConnections`,
`WebSocketFrameGuard`); its record names no client side. Read on today's code:
the caller opens through `WebSocket.connect`, so dart:io's transformer, which
sums fragments until FIN with no ceiling, is unguarded there. Round 394 found
the same one-door gap for http2's CONTINUATION guard. B-267 and B-270 not
taken, left open.

## Hypothesis

A server that sends fragments without FIN grows the client without bound,
and the client never closes.

## Before

```
  unfinished fragments   client closed   server saw close   RSS
  4 x 1 MiB              no              no                 +15 MiB
  256 x 1 MiB            no              no                 +354 MiB
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r756_unfinished_message_to_client.dart`

## Mechanism

dart:io assembles a whole message before delivering it; the multiplexer's
cap sees nothing until FIN, and FIN never comes.

## Fix

`connectBounded`, beside `upgradeBounded`: dart:io's client handshake (same
headers, Basic auth from `userInfo`, the 101 / Upgrade / Accept checks, the
same `WebSocketException`) over the attempt's `HttpClient`, then
`WebSocket.fromUpgradedSocket` over the server's `_BoundedSocket`. The guard
reads the mask bit, so it parses unmasked server frames unchanged.
`openWebSocket` takes it when compression is off (the default);
`connect()` passes the multiplexer's reassembly cap, never below the default
policy's.

That floor is the server's rule too, and the suite proved it necessary: with
the bare policy cap, `oversized_response_keeps_connection_test.dart` failed 5
of 5, a whole 2 MiB response to a 256 KiB client dropping the connection
instead of failing its call with 8.

## After

```
  256 x 1 MiB    server saw close after 18 fragments    RSS +30 MiB
  4 x 1 MiB      not closed                             RSS +13 MiB
```

Cost, `r756_throughput.dart`, warm rounds:

```
                 5000 unary        stream 200 x 256 KiB
  guard off      3656 / 3411 ms    553 / 546 ms
  guard on       3673 / 3429 ms    543 / 518 ms
```

Within noise, so no speed trade to put to the owner.

## Canary

`an unfinished message from the server is refused past the ceiling`, the
guard's ceiling forced to null, failed with:

```
  Expected: not null
    Actual: <null>
  64 MiB of one message buffered, RSS +114 MiB
```

The rest of the websocket suite, every connect now through `connectBounded`,
is the guard for the handshake: 295 of 295.

## The verdict questions

1. Yes: 4 and 256 fragments differ only in count.
2. Yes: +15 against +354 MiB, growing with N.
3. RSS of the process; the close counted by the server's writes.
4. n/a, not a zero.
5. Quoted above.
6. One mechanism; the floor is a parameter of it, pinned by the existing
   oversized-response tests.
7. From the tables.
8. Round 611's record was not taken as covering the client: today's caller
   code shows `WebSocket.connect`. B-267, B-270 left open.
9. None.
A1. The attacker is the server, the victim the client; separate processes
    in production, one process in the bench.
A2. Volume: the bench sends it.
L1. The refusal is the frame guard: the server's write fails after the
    ceiling's worth of fragments, not at a neighbouring limit.

## Gate

`melos run analyze`, `test:unit` (websocket 295), `format:check`,
`license:check`: green. `test:web`: green.

## Not fixed

The web client: the browser assembles messages before the page sees them,
out of reach. With compression on, dart:io's handshake is still used,
already documented as unsafe against hostile servers. The refusal is a
dropped socket, not a 1009 close, as on the server (round 611).

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md` — `applied: [..., 756]`.
New bench `../probes/P-261-an-unfinished-message-to-the-client.md`.
Round 611 and P-216, the server side.
