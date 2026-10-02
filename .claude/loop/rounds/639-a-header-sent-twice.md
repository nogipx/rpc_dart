---
round: 639
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-13
bench: P-225 — new
budget: probes 4/5, canaries 1/5
commit: yes
release: changelog
---

# Round 639 — a header sent twice

## Target

The owner asked for critical defects in rpc_dart. Both critical findings of the
2026-10-02 audit were in code that parses a peer's bytes, so the round built
the instrument for that class, which the project did not have: four fuzzers
(P-225) over every decoder, a server, a client and a real websocket server.

## Hypothesis

A fuzzer reaches parse paths that reading and targeted probes did not.

## Before

```
websocket server, compression on, 300 hostile connections
  UNCAUGHT HttpException: More than one value for header sec-websocket-key
    _HttpHeaders.value
    WebSocketTransformer.isUpgradeRequest
    rpcWebSocketConnections.<anonymous closure> (websocket_io_connections.dart:131)
  19 times
witness, compression on    uncaught HttpException, no answer
witness, compression off   no crash, and no answer at all: the request hangs
```

Everything else the fuzzers drove was clean; P-225 has the numbers.

## Control

The same server answers a well-formed client before and after every attack;
compression off survives the same request.

## Mechanism

RPC-13, an async error with nowhere to go. The upgrade filter calls dart:io's
`isUpgradeRequest`, which reads headers with `value()`, and that THROWS on a
repeated header. `Stream.where` turns the throw into an error event. With
compression off our `_upgradeEach` receives it and the request is merely never
answered; with compression on the event reaches dart:io's
`WebSocketTransformer`, whose subscription has no error handler, so it lands in
the root zone and the process dies. The filter's own comment already named the
root zone and guarded `allowUpgrade` for this reason; the dart:io call two
lines below was not guarded.

## After

The call is wrapped; a request it cannot classify is answered 400, as any
non-upgrade request is. Both arms of the witness are green, and the websocket
fuzzer with compression on reads `uncaught 0` over 1000 attacks.

## Canary

The before lines are the witness and the fuzzer against the unguarded call.

## Gate

`analyze` and `format` on rpc_dart_websocket green, `melos run test:unit` green
(exit 0). No web arm: the change is in the dart:io-only upgrade path.

## Not fixed

The fuzzers live in `.dart_tool/probe/` and run by hand; none is in the gate.

## Links

Bench `../probes/P-225-what-a-fuzzer-finds-in-the-decoders-and-the-servers.md` — new.
Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [..., 639]`.
Test `packages/transport/rpc_dart_websocket/test/a_repeated_websocket_key_is_refused_test.dart`.
