---
round: 599
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-21
bench: none — the observable is which header value crossed the wire on each upgrade, read on the server side by the test
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
severity: S2
---

# Round 599 — the token captured once

## Target

B-139 item 4, the last item of the lead, owner-requested in round 597's session:
`RpcWebSocketCallerTransport.connect()` captures `headers` once for every
reconnect, so an expiring token cannot be refreshed.

## Hypothesis

A reconnect after the token expires presents the token minted for the first
upgrade. Lens RPC-21 (drive the lifecycle twice): one upgrade is fine, the second
is the one that is wrong.

## Before

`connect()` takes a `Map<String, Object>? headers` and the reconnect factory closes
over that one map. There is no way to supply a value computed per upgrade.

## Mechanism

The reconnect factory carries the same headers deliberately, so a reconnect can
authenticate at all (round that added `headers`); a static map is the only shape it
can carry.

## After

`connect(headersProvider: ...)`, a `FutureOr<Map<String, Object>> Function()`
called for the first upgrade and again for every reconnect. Passing it together
with `headers` is an `ArgumentError`. Read on the server: the first upgrade carries
`Bearer t1`, the reconnect `Bearer t2`.

## Canary

1. The provider evaluated once and cached (the wrong neighbour): `a headers provider
   is asked again on every reconnect` fails, `Expected: ['Bearer t2'] Actual:
   ['Bearer t1'] — the reconnect presented the token minted for the first upgrade`.
2. The both-given check off: `headers and a headers provider together are refused`
   fails, `Expected: throws <Instance of 'ArgumentError'> ... emitted <Instance of
   'RpcWebSocketCallerTransport'>`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages,
rpc_dart_websocket +250, rpc_dart +1892), `melos run format:check`, `melos run
license:check` — green. `websocket_web_smoke_test` green on `-p node` (the provider
is evaluated on the web too and ignored there, like `headers`).

## Not fixed

`connectTimeout` does not cover the provider's own time; an application whose
token refresh hangs holds the reconnect for as long as it hangs.

## Links

Lead `../backlog/B-139-websocket-cleanup-items.md` — closed.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [599]`.
Test `packages/transport/rpc_dart_websocket/test/connect_headers_and_timeout_test.dart`.
