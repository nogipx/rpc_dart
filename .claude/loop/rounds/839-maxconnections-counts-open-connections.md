---
round: 839
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-05
bench: P-310 — new
commit: yes
severity: S1 — "a documented or default setup that does not work at all"
release: changelog
---

# Round 839 — maxConnections counts open connections

## Target

Picked through the network-audit skill (`known`, priority order). KV-R-07
read off current code: `parseGrpcTimeout` is lenient (`int.tryParse` takes a
sign and whitespace), S3 at most against the S1 bar, so not taken. KV-G-03
was NOT re-measured; rounds 812 and 831 suggest it is covered, which is a
record, not a ruling, and it stays a candidate. Taken instead: round 838's
`bindRpcWebSocketHttpServer`, a day old, whose witness checks that a
connection past `maxConnections` is refused while nothing checks the release.
RPC-05 asks where a count is charged and where it is returned, on every
ending.

Class counted first (L-12): two socket wrappers return a slot from their read
subscription's handlers, `_HeaderBoundedSocket` (websocket) and
`_WatchedSocket` (`rpc_dart_http/lib/src/peer_watch.dart`). `detachSocket`
appears only in `rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart`
(three sites); `rpc_dart_http/lib` and `rpc_dart_http2/lib` have none.

## Hypothesis

A connection returns its `maxConnections` slot when it ends. Fails if some
ending leaves the slot taken, so a server with the cap refuses honest clients
after enough of them have come and gone.

## Before

```
arm (4 endings, then one call)  cap 2      no cap (control)
ws call, client closes          REFUSED    served
ws upgraded, client silent      REFUSED    served
ws upgraded, server closes      served     served
plain GET, server refuses       served     served
connect, client destroys        served     served
header timeout cut              served     served
byte cap cut                    served     served
```

With the fix ablated and `pingInterval: 300 ms`, `lsof -p` on the server
shows no socket left on the port (`held=[]`) in both refused arms: the slot
outlives the connection. "Server closes" (a frame header over the limit) was
reached in 8 of 8 tries.

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r839_connection_slots.dart`.

## Mechanism

dart:io's `_HttpDetachedIncoming.listen` (sdk `_http/http_parser.dart`) calls
`onData`, `onError` and `onDone` on the subscription the wrapper returned,
replacing the wrapper's handlers, and `_end()` lived in them. After the
upgrade only `destroy()` on the wrapper returned the slot; a client close or
the keepalive's close went through `close()` and never did.

## After

```
arm                             cap 2      no cap
ws call, client closes          served     served
ws upgraded, client silent      served     served
(the other five arms unchanged: served / served)
```

The fix: `_socket.done` also ends the wrapper, once (`_ended` guards it).

## Canary

Witness `packages/transport/rpc_dart_websocket/test/a_closed_connection_returns_its_slot_test.dart`.

- Release removed (`if (1 < 0)` around the `done` line): "WITNESS: a session
  the client closes returns its slot" failed with `RpcStatusException(14):
  WebSocket connect failed: HttpException: Connection closed before full
  header was received`; "WITNESS: a session the keepalive ends returns its
  slot" failed with `Expected: true Actual: <false>`. GUARD green.
- The wrong neighbour, the slot returned at the end of the header block
  (`_end()` after `_inHeaders = false`): "GUARD: an open session keeps its
  slot" failed with `Expected: false Actual: <true>`; both witnesses green.

Three canary runs of five; the second witness was rewritten once (see Not
fixed) and canaried again.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart_websocket +331, rpc_dart +2202 ~1, conformance +512 ~150);
`format:check` SUCCESS; `license:check` compliant. Package run before the
gate: rpc_dart_websocket +331.

## Siblings

- websocket: fixed here
- http: n/a — `rpc_dart_http/lib` calls no `detachSocket`, so dart:io never replaces `_WatchedSocket`'s handlers; measured with the http probe at cap 1: "connect, client destroys" and "header timeout cut" served. The two answered arms read REFUSED because they were read before the client's close arrived; round 842 measured them again with a 3.5 s settle: served, with an ablation reading REFUSED
- http2: n/a — no connection cap and no socket wrapper in `rpc_dart_http2/lib`
- channel: n/a — no listening socket and no connection cap
- isolate: n/a — no listening socket and no connection cap
- wasm: n/a — no listening socket and no connection cap
- caller: n/a — the cap is a server's; no caller counts accepted connections
- responder: fixed here (`websocket_http_server.dart` is the responder side)

## Not fixed

- The first version of the second witness destroyed a raw client after the
  upgrade and read the server 500 ms later, while both ends were still
  ESTABLISHED. Corrected in round 842: that was the ~2.1 s delay before a
  peer's close reaches the server here (P-295, L-25), not dart:io holding the
  socket. The witness, a silent client ended by the keepalive, is unaffected.
- Never shipped: round 838's helper is unreleased, so the next release carries
  the fix with the feature.

## Links

Lens `../lenses/RPC-05-concurrency-limit-charge-point.md`. Bench
`../probes/P-310-connection-slots-per-ending.md`. Round
`838-the-websocket-upgrade-gets-the-header-bound.md` (the code), round
`811-an-unfinished-header-block-is-bounded.md` (the http original).
