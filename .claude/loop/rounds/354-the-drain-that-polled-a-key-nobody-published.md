---
round: 354
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-25
bench: P-46 — new
commit: yes
---

# Round 354 — the drain polled a key nobody published

## Target

The owner's 6.0.0 review list, P0 item 4.

RPC-25's shape — the same abstraction implemented more than once, drifting.
`RpcResponderEndpoint` and `RpcPeerEndpoint` are sibling subclasses that both
serve calls through `RpcResponderPipelineMixin`, and both override
`collectEndpointMetrics`. The responder's override computed five metrics about
responder streams inline; the peer's called the shared
`collectResponderMetrics()` and stopped. Those five were the drift.

**Scope counted before the fix.**

```
metric                 RpcResponderEndpoint  RpcPeerEndpoint
registeredContracts    yes (mixin)           yes (mixin)
registeredMethods      yes (mixin)           yes (mixin)
isListening            yes (mixin)           yes (mixin)
isDraining             yes (mixin)           yes (mixin)
openStreams            yes (mixin)           yes (mixin)
preMethodBufferedBytes yes (mixin)           yes (mixin)
metadataStreams        yes (inline)          NO
bufferedMessages       yes (inline)          NO
clientStreamBuffers    yes (inline)          NO
activeResponders       yes (inline)          NO
contractKeys           yes (inline)          NO
```

Five metrics, one endpoint class. And the consumers: `_inFlightCalls()` exists
in two servers, `rpc_dart_websocket` and `rpc_dart_http2`, both polling
`activeResponders` with `?? 0`. Only the websocket server can hold a peer
endpoint — http2's `_endpoints` is typed `List<RpcResponderEndpoint>` and it has
no peer callback — so only one was ever affected, and one fix covers both.

## Hypothesis

`stop(drainTimeout:)` is documented as letting in-flight calls finish, and its
own comment says peer endpoints are deliberately included: *"counting only
RpcResponderEndpoint would drain a peer server instantly"*. If the count comes
from a key the peer endpoint never publishes, then including them in the list
achieved nothing and the comment describes an intent rather than a behaviour.

## Before

```
arm         activeResponders  stop waited   the in-flight call
responder   1                 1746ms        returned "finished"
peer        null              1ms           status 14
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/drain_in_peer_mode.dart`.
One variable: `onEndpointCreated` against `onPeerEndpointCreated`.

`null`, not `0`. The key was absent, and `?? 0` turned an absent key into an
idle server — so the drain answered a question it had never actually asked.

## Mechanism

`_inFlightCalls()` reads `metrics['activeResponders'] as int?` and falls back to
0. `RpcPeerEndpoint.collectEndpointMetrics` adds `collectResponderMetrics()` and
`collectCallerMetrics()`, neither of which contained that key: it was computed
in `RpcResponderEndpoint`'s own override, beside four others, from
`_respStreams` — state the mixin owns and both siblings have.

## After

```
arm         activeResponders  stop waited   the in-flight call
responder   1                 1744ms        returned "finished"
peer        1                 1726ms        returned "finished"
```

All five moved into `collectResponderMetrics()`, so there is one home for
"metrics about responder streams" and it is the mixin that owns the streams.
`RpcResponderEndpoint`'s override is now three lines and adds nothing of its
own — which is the point: the metrics were never responder-endpoint-specific.

## Canary

`activeResponders` removed from the mixin's map (`if (1 > 1)`). It fails the new
peer witness AND the existing responder test:

```
a drained stop lets a peer-mode call finish
  Expected: 'returned finished'  Actual: 'status 14'
a peer endpoint reports the call the drain polls for
  Expected: <1>  Actual: <null>
graceful_drain_on_stop_test: a drained stop lets an in-flight call finish
```

Failing both is correct and is the evidence that there is now ONE home rather
than two copies. The CONTROL (a forceful stop still cuts the call off with
UNAVAILABLE) and the GUARD (an idle server does not wait out its budget) stayed
green under the ablation — the second matters, because a count that never falls
to zero would pass the witness and hang every shutdown.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS at load 10.76; `melos run
format:check` SUCCESS; `melos run license:check` 1346/1346;
`melos run test:wasm` `+40`.

## Not fixed

**`RpcWebSocketServer.endpoints` is still empty in peer mode**, which the owner
also named. It is `whereType<RpcResponderEndpoint>()` over a list that holds
both, and it cannot simply be widened: the return type is fixed by
`IRpcServer.endpoints`, `List<RpcResponderEndpoint>`, which all three servers
implement. Making it honest means changing that interface to `RpcEndpointBase`
— a breaking change to a published API, across three packages, for a getter
whose only in-repo readers are tests. That is a design decision, not a repair.
Filed as B-37.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` (fourteenth
application; the first on the endpoint classes rather than the transports).
Bench `../probes/P-46-drain-in-peer-mode.md`, new.
Lead `../backlog/B-37-endpoints-getter-excludes-peers.md`, new.
Catalog shapes U-14 and U-13 — the witness is the mirror of a responder-mode
battery that had already paid.
