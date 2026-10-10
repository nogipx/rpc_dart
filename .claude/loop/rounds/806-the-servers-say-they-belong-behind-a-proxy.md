---
round: 806
verdict: DEFERRED
packages: [rpc_dart_http, rpc_dart_websocket, rpc_dart]
lens: RPC-18
bench: none — the owner's decision is documentation; P-277's measurement stands and no code changed
commit: yes
severity: S2
release: changelog
---

# Round 806 — the servers say they belong behind a proxy

## Target

B-274, decided by the owner 2026-10-10 (option 3): document now, in the
READMEs of rpc_dart_http and rpc_dart_websocket and in the skill, that both
servers belong behind a reverse proxy that bounds connections and header
time; file option 1 as its own lead.

Before writing it, the claim was re-read in today's code, since round 804
changed `rpc_http_server.dart`: `RpcHttpServer` still has no connection
limit and no header deadline (its `bodyIdleTimeout` starts after the
headers), and `rpcWebSocketConnections` still runs on the application's
`HttpServer`.

## Hypothesis

P-277's finding holds at 0b9d5a08: nothing in either server bounds the
number of connections holding an unfinished header block.

## Before

The READMEs said nothing about connections before the upgrade
(websocket) or at all (http); the websocket README's `maxConnections` line
read as if it bounded every connection.

```
P-277 (round 782, 5db1dd59): 300 connections x 900 KiB unfinished headers
  rpcWebSocketConnections on HttpServer   +313 MiB, none closed at 140 s
  RpcHttpServer                           +311 MiB
```

## Mechanism

dart:io buffers a request's header block below every rpc_dart limit (RPC-18),
and `HttpServer.idleTimeout` does not apply to a request whose headers never
end; `RpcWebSocketServer.maxConnections` counts upgraded channels only.

## After

rpc_dart_http README: a "Deploy behind a reverse proxy" subsection under
Limits. rpc_dart_websocket README: the proxy section says `maxConnections`
counts upgraded connections only, and what holds the rest. rpc_dart-core
skill, security reference: the policy bounds what reaches rpc_dart, not raw
connections or unfinished headers; deploy an exposed server behind a proxy.
B-285 holds option 1.

## Canary

n/a for the code (none changed). The documentation's claim was checked
against the code instead of the old record: no connection cap or header
deadline exists in `rpc_http_server.dart`, `peer_watch.dart` or
`websocket_io_connections.dart` at 0b9d5a08.

## The verdict questions

1. n/a: no new measurement; P-277's control (an ordinary request on the
   same server) stands.
2. n/a.
3. n/a.
4. n/a.
5. n/a: documentation only.
6. n/a.
7. DEFERRED for the owner's reason: option 1 is "later", filed as B-285.
8. B-274's text was re-checked against today's code (round 804 moved the
   file), not trusted.
9. none.
10. No code in a sibling group changed.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`check:skills` and `license:check` green. No Dart source changed since
0b9d5a08, whose full gate is in round 805; analyze and the suites were not
re-run for two README edits and a reference paragraph.

## Siblings

No code changed.

## Not fixed

- The defect itself: B-285 (connection cap and header deadline).
- Not re-measured with P-277 (a Python bench): the code it measured has the
  same absence today, which is what the documentation states.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`. Bench
`../probes/P-277-held-request-header-blocks.md`. Leads
`../backlog/B-274-servers-hold-unfinished-request-headers-for-any-number-of-peers.md`
(closed), `../backlog/B-285-the-http-servers-have-no-connection-cap-or-header-deadline.md`
(new).
