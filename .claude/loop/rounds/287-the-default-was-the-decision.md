---
round: 287
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-25 — reused
commit: yes
---

# Round 287 — the default was the decision

## Target

B-27's remaining half, and the owner's answer to "do we have anything to fix, or
is everything perfect". Three findings had been sitting measured and deferred,
and the deferral was mine rather than the code's. This closes the one with the
clearest measured benefit.

## Hypothesis

`pingInterval` is the only mechanism that reclaims a connection from a peer that
has spoken HTTP/2 and then gone silent — round 275's `prefaceTimeout`
deliberately does not cover that case, because 24 preface bytes buy past it. It
shipped `null`. So **the shipped default decided whether a server had any bound
on held endpoints at all, and the shipped default was none.**

## Before

P-25 reused, its control repeated. 200 sockets, this server.

```
arm                     endpoints  contracts built  contracts disposed
default (pingInterval null)   200              200                   1
ping    (pingInterval on)       0              200                 201
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/a_tcp_syn_builds_an_endpoint.dart`

The mechanism was never in doubt — round 274 measured it. What was open is which
of those two rows a server gets without being told to ask for one.

## Mechanism

An endpoint holds the application's contracts, and a contract that is never
disposed keeps whatever it owns for the life of the process. Nothing counts
connections, and every other limit this server has is per connection, so a peer
that speaks the preface and stops is beneath all of them.

## After

`pingInterval` defaults to 30s. A conforming peer answers a PING by
specification, so a live client is untouched; a silent one is dropped after
`pingTimeout`.

## Canary

n/a for a default. The behaviour it switches on is already pinned by
`test/server_keepalive_reclaims_half_open_test.dart`, which passes an explicit
interval — and that test is what caught the round's real mistake, below.

**The gate caught a defect I introduced, which is the part worth recording.** I
defaulted `pingTimeout` to 20s alongside it. Null there means *follow
`pingInterval`*, and that fallback is load-bearing: with a concrete default, a
caller passing `pingInterval: 2s` waited 20s for the ACK, and the keepalive test
went red on its own budget —

    Expected: empty
      Actual: [RpcResponderEndpoint, RpcResponderEndpoint, RpcResponderEndpoint]
    a half-open connection was never reclaimed

`pingTimeout` is left `null`, with the reason in the argument list.

> **A null that MEANS something cannot be given a default.** Two parameters that
> read as a pair are not necessarily a pair: one was a plain off-switch, the
> other an "inherit from its sibling" sentinel, and defaulting both treated them
> alike.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.
`rpc_dart_http2` alone: 199 tests.

## Not fixed

**The websocket server's `pingInterval` is still opt-in.** Its own doc carries
the same measurement shape (`pingInterval 3s : endpoints 0, contracts disposed 5
by t+10s`), so the argument transfers — but it is a second behaviour change on a
different API surface and B-27 measured http2. Named here rather than changed
blind.

The 30s figure: take the shortest idle timeout on the path — load balancers
commonly use 60s — and halve it. `null` restores the old behaviour, and the doc
says so in those words.

## Links

RPC-22 (`applied:` gains 287). Bench P-25 reused, control repeated. B-27 closes.
Round 275 shipped the other half and is what makes this one necessary rather
than redundant: the two stages need two mechanisms.
