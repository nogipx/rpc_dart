---
round: 276
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-22
bench: P-26 — new
commit: yes
---

# Round 276 — the same defect in the sibling

## Target

RPC-22's detector run over the OTHER servers' rejection exits, which rounds
271-275 had only done for `rpc_dart_http` and for the pre-protocol stage. The
websocket server has exactly one: `_refuse` in `websocket_io_connections.dart`,
reached when `allowedOrigins` or `allowUpgrade` turns a request away.

Its comment already pointed at the sibling — *"The HTTP/1.1 transport's `_reject`
learned this the same way"* — for the DRAINING half. Round 272 had just added the
half it did not copy, because that half did not exist yet when this was written.

The CORS preflight in `rpc_dart_http` was checked first and is clean:
`handlePreflight` is synchronous and drains nothing, so it holds nothing.

## Hypothesis

`_refuse` drains the request body with no deadline, and it is `unawaited`, so the
accept loop takes the next connection immediately and any number of these run at
once with nothing counting them.

## Before

16 sockets promise a 100000-byte body, send five bytes and hold. Server
configured with an `allowedOrigins` allowlist.

```
arm       origin     shape    window  answered   first answer
accepted  allowed    upgrade   3s     16 of 16   101 Switching Protocols
refused   rejected   upgrade   3s     16 of 16   403 Forbidden
plain     rejected   POST     12s      0 of 16   -
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/refused_upgrade_has_no_deadline.dart`

**The request SHAPE is the whole trick and the first attempt missed it.** The
upgrade-shaped attack answered 16 of 16 and read as clean; dart:io hands a
CONNECTION-UPGRADE request no body at all. `_upgradeAllowed` gates every request
reaching the server, not just upgrades, so a plain POST reaches `_refuse` just
the same — and holds forever.

Cost to the attacker: ~120 bytes and one socket, unauthenticated. **The path
exists only when the origin check is configured**, so it is reachable exactly on
the servers that turned the security control on.

## Mechanism

Draining is necessary — dart:io tears the connection down before the status is
flushed if the body is left unread — but it is work an unauthenticated peer
commands, on a path with no admission control and, until now, no deadline.

## After

```
arm       origin     shape    window  answered   first answer
plain     rejected   POST     12s     16 of 16   closed
```

`_refuse` now drains under `_refusalDrainBudget` (5s, a constant rather than a
knob: a client that has just been told 403 has no reason to be sending a slow
body) and CANCELS the subscription on expiry — a `.timeout()` on the drain
future would answer while the read loop kept running.

## Canary

`test/a_refused_upgrade_has_a_deadline_test.dart` — with the deadline removed the
witness failed with

    Expected: empty
      Actual: WhereIterable<String>:['STILL DRAINING' x8]
    the refusal drain must have a deadline

after the full 12s, while both GUARDs kept passing: a permitted origin still
upgrades (101, and the channel stream still yields 8), and a refused UPGRADE
still gets its 403.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.

## Not fixed

An over-budget refusal settles by CLOSE rather than by a 403, for the same
reason as round 272: dart:io cannot flush a response on a request whose body was
not consumed. Delivering it was already best-effort — the pre-existing
`catchError` says so — and the third test pins that an ordinary refusal is
unaffected.

The websocket server's second stage is untouched and matches the http2 finding
of round 274: a peer that COMPLETES the upgrade and then says nothing holds an
endpoint, bounded only by `pingInterval`, which is opt-in here too. That is the
same open decision B-27 records, one transport over.

## Links

RPC-22 (`applied:` gains 276) — its first application outside the package it was
derived on, which is what a lens is for. Bench P-26, new. Round 272 is the
sibling this one copies, and U-14 is the catalog shape that says to look.
