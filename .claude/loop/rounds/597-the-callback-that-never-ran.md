---
round: 597
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-04
bench: none — construction-time behaviour, read off the code and witnessed by tests; there is no quantity to measure
budget: probes 0/5, canaries 0/5
commit: yes
release: breaking
severity: S2
---

# Round 597 — the callback that never ran

## Target

B-139, the last open lead filed against rpc_dart_websocket. Round 535 said to split
it first; the split is:

```
item                                     how settled
2  close-code rows said to be dead       keep — judgement, a test pins the mapping
4  connect() captures headers once       owner: implement (round 599)
5  record allocated to silence analyzer  keep — documented, once per connect
6a peer/responder branches duplicated    owner: dedupe — this round
6b onEndpointCreated ignored in peer mode owner: ArgumentError — this round
6c createWithContracts drops logController owner: add it — this round
6d no connection cap                     owner: implement (round 598)
7  responder transport forwards members  read: hides nothing the pipeline checks
```

The owner decided 4, 6a-6d this session. This round takes the three that live in
`RpcWebSocketServer`'s construction and connection setup.

## Hypothesis

With both callbacks passed, the server takes the peer branch and never calls
`onEndpointCreated`, so the contracts registered there are never registered and
every connection serves nothing. `createWithContracts` cannot be given a
`LogController` at all.

## Before

Read off `rpc_websocket_server.dart`: `if (_onPeerEndpointCreated != null) {...}
else { ... _onEndpointCreated?.call(...) }` — the responder callback is in the
else branch only. `createWithContracts` has no `logController` parameter, and the
witness for it did not compile:
`Error: No named parameter with the name 'logController'`.

Item 7, read: `RpcWebSocketResponderTransport` implements `IRpcSecurityPolicyAware`
and `IRpcFlowControlled`, the two capabilities the pipeline discovers with `is`.
The one it hides is `IRpcReconnectableTransport`, which nothing server-side asks
for. No defect today.

## Mechanism

The two endpoint types are siblings, so the server can build only one per
connection; it chose silently.

## After

- Passing both callbacks throws `ArgumentError` at construction.
- `createWithContracts` takes `logController` and forwards it.
- The two branches of `_handleConnection` share one `start()` and one `sink.done`
  wiring; order (register, callback, start, wire) unchanged.

## Canary

Both switched off together, each test naming its own half:
- the constructor check off: `both endpoint callbacks are refused at construction`
  fails, `Expected: throws <Instance of 'ArgumentError'>, Actual: ... returned
  <Instance of 'RpcWebSocketServer'>`;
- the factory not forwarding (parameter kept): `createWithContracts hands its
  LogController to the endpoints` fails, `Expected: non-empty, Actual: []`.

The dedupe is a refactor; the existing server tests (245 in the package, including
the peer-mode ones) are its guard.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages,
rpc_dart_websocket +245, rpc_dart +1892), `melos run format:check`, `melos run
license:check` — green.

## Not fixed

The connection cap (6d) and the headers callback (4) — the owner asked for both;
they are rounds 598 and 599. Items 2, 5 and 7 are closed by reading.

`release: breaking` because code passing both callbacks now throws where it used to
start a server that served nothing.

## Links

Lead `../backlog/B-139-websocket-cleanup-items.md` — open, narrowed to 4 and 6d.
Lens `../lenses/RPC-04-capability-hidden-by-wrapper.md` — `applied: [597]` (item 7).
Test `packages/transport/rpc_dart_websocket/test/server_construction_is_unambiguous_test.dart`.
