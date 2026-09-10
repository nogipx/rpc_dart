---
round: 275
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-25 — reused
commit: yes
---

# Round 275 — a deadline on saying nothing

## Target

B-27, deferred by round 274 and answered by the owner within the same session:
of the two candidate fixes, **the deadline**. This round implements it, and
also corrects the option as it was put to them — the round's own measurement
turned the fix weaker than the question implied, and the correction is in
"Not fixed".

## Hypothesis

A timer armed on accept and disarmed by the peer's connection preface bounds the
hold that 274 measured, without touching a conforming client.

The version originally proposed — disarm on the FIRST INBOUND BYTE — is worth
naming as refuted before it ships: one byte would disarm it, so the attacker's
cost would rise from 0 to 1. The disarm has to be the 24-octet preface, and even
then the cost only rises to 24.

## Before

P-25 reused, its control repeated first. 200 sockets against
`prefaceTimeout: 500ms`, arms differing in what the socket sends and whether the
deadline exists.

```
arm      prefaceTimeout  bytes sent  endpoints after 2s  contracts disposed
off      null            0                  200                  1
default  500ms           0                    0                201
preface  500ms           24                 200                  1
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/a_tcp_syn_builds_an_endpoint.dart`

`off` is the ablation and reproduces round 274's number. `preface` is the one
that matters twice over: it proves the deadline bounds SILENCE rather than
connections, and it is the residual — 24 bytes buys the hold straight back.

## Mechanism

`_HeaderBlockScanner` already tracks `_prefaceRemaining`, because the preface
must be skipped before frame parsing starts. It is the only thing in the
transport that sees raw bytes before package:http2 does, so it is the only place
that can tell "this peer has begun speaking HTTP/2" from "this peer has been
accepted". It gains an `onPrefaceComplete` callback, following `onGoaway`, which
was added for the same reason.

`RpcHttp2Server` arms a `Timer` where the endpoint is registered, and cancels it
in three places: the preface callback, both branches of the `socket.done`
release wiring, and the constructor's catch.

## After

The `default` arm above: 200 silent sockets go from 200 endpoints to 0, all
contracts disposed. The `preface` arm is unchanged at 200, which is the point.

## Canary

`test/a_silent_socket_is_dropped_test.dart` — with the deadline switched off at
the arming site the witness failed with

    Expected: <0>
      Actual: <8>
    and then be dropped at the deadline

while both GUARDs passed: a peer that sends the preface is still held after four
deadlines, and an ordinary `RpcHttp2CallerTransport` call still round-trips. The
witness waits for the RISE to 8 before asserting 0, so it cannot pass on a
server the connections never reached.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green. `rpc_dart_http2`
alone: full suite green.

## Not fixed

**The correction the owner is owed.** The option they chose was put to them as a
deadline disarmed by the first byte; that version is worthless, and even the
preface version only moves the attacker's cost from 0 bytes to 24. What this
fix actually buys is a bound on traffic that never speaks HTTP/2 at all — port
scanners, TLS probes, misdirected HTTP/1.1 clients, a load balancer that
pre-warms TCP and never follows through. Those are the realistic sources of
accumulated silent connections and they are now bounded. **A determined attacker
is not**, and the mechanism for that half already exists and already works:
round 274's `ping` arm took 200 endpoints to 0 with `pingInterval` alone.
`pingInterval` remains null by default, which is still the owner's call and is
the larger of the two decisions.

**The default is a behaviour change.** `prefaceTimeout` defaults to 30s, so a
client that opens the TCP connection eagerly and speaks HTTP/2 much later is now
dropped where it was not. Passing null restores the old behaviour, and the doc
comment says so in those words. Chosen over defaulting to null because a fix
that ships disabled repeats the exact failure this round is about — `pingInterval`
is off by default and that is why 274 had anything to find.

**Still open in B-27**: deferring the endpoint construction itself until the
peer speaks. That remains the correct shape and remains larger than a round.
The lead is updated rather than closed.

## Links

RPC-22 (`applied:` gains 275). Bench P-25 reused, control repeated. B-27 partly
discharged. Round 274 is the measurement this one acts on.
