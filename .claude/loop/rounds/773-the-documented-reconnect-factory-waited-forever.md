---
round: 773
verdict: FIXED
packages: [rpc_dart]
lens: RPC-28
bench: P-273 — new
commit: yes
release: changelog
---

# Round 773 — the documented reconnect factory waited forever

## Target

RPC-28's sweep over its 13 files, the lens's first round of its own. The
transports' opens are bounded at every stage, and their witnesses pass
(isolate startup 27 tests, http2 SETTINGS and silent tunnel 3, websocket
connect timeout and released socket 12). Left: `RpcClientConnection`,
whose `connectTimeout` defaulted to null, the RPC-28 shape "a timeout
whose default is null", and whose own dartdoc example builds a transport
on `WebSocketChannel.ready`, which nothing bounds.

## Hypothesis

The documented reconnecting client, against a peer that accepts and never
answers the upgrade, stays connecting forever.

## Before

P-273:

```
  documented  after 40 s: RpcClientConnecting@12ms            (nothing more)
  bounded     after 8 s:  RpcClientConnecting@14ms -> RpcClientDisconnected@2016ms
```

## Mechanism

Nothing above the factory bounds its future when `connectTimeout` is
null, and the dartdoc factory awaits `ready`, which `web_socket_channel`
does not bound either. Fix: `connectTimeout` defaults to 30 s, the value
the websocket and http2 transports use; `null` still disables it. The
skill's resilience reference says so.

## After

`packages/core/rpc_dart/test/resilience/a_silent_factory_is_bounded_by_default_test.dart`:
a factory that never completes, default constructor, ends in
`RpcClientDisconnected` after 30 s.

## Canary

Default reverted: `still connecting after 45 s`.

## The verdict questions

1. The arms differ in `connectTimeout` only.
2. Yes: Disconnected at 2 s against Connecting at 40 s.
3. The connection's own state stream.
4. The documented arm is a "nothing happened" reading; 40 s is past the
   30 s every transport bounds itself by, and the bounded arm shows the
   machinery that would end it.
5. Yes, above.
6. One half.
7. FIXED.
8. The transports' opens were taken as clean on their witnesses, run in
   this round, not on their records.
9. None.
A1. n/a.
A2. Latency (a peer that never answers); the bench supplies it with a real
    socket.
L1. n/a.

## Gate

`melos run analyze`, `format:check`, `check:skills`, `test:unit` green.

## Not fixed

Nothing.

## Links

Probe `../probes/P-273-a-reconnecting-client-against-a-silent-upgrade.md`.
Lens `../lenses/RPC-28-a-connect-timeout-that-ends-a-stage-early.md`.
