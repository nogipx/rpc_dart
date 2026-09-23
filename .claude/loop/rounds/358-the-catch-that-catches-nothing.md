---
round: 358
verdict: DEFERRED
packages: [rpc_dart_websocket]
lens: RPC-13
bench: P-49 — new
commit: yes
---

# Round 358 — the catch that catches nothing

## Target

The owner's 6.0.0 review list, P1 item 9, which round 353's fixture had already
tripped over: `RpcWebSocketChannel.send` calls `_ws.sink.add` with no guard, and
in the race with a close it throws.

RPC-13: an async error with nowhere to go. The item as filed proposes the fix —
*"`send` → no-op"* — and this round's result is that the proposed fix does not
work, for a reason worth having in writing.

**Scope counted before the fix.** Every channel `send` that writes to a sink it
does not own:

```
site                                    guarded?
RpcWebSocketChannel.send                NO
RpcWebSocketChannel.close               yes -- try/catch around sink.close()
RpcWebSocketChannel.closeForProtocolError  yes -- same
isolate _sendPort.send                  yes, and deliberately RETHROWS typed:
                                        "a dead peer is SILENT ... so this is
                                        one message's problem"
RpcFlutterWasmBridge.send               guarded by _closed || _dead, awaits a
                                        platform-channel reply
RpcFrameMultiplexedChannel.send         delegates; no sink of its own
```

One unguarded site — and it is in the same file as two guarded ones.

## Hypothesis

`send` guards on `_closed`, which is set by our own `close()` and by `onDone`.
Between the socket dying and `onDone` being delivered the guard reads false, so
the add goes to a sink that may refuse it. If the send paths above are detached,
nothing catches the refusal.

## Before

```
arm                                 isClosed   closeCode  send
live socket (control)               false      -          returned
our close() first (control)         true       -          returned
peer closed, same turn              false      -          returned
peer closed, +1 turn                false      -          returned
peer closed, +50ms (onDone in)      true       1005       returned
our raw socket, behind the channel  true       1006       returned
our raw socket, same turn           false      -          ROOT-ZONE CRASH
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/send_into_a_dead_socket.dart`.

Three things the table settles that the item's wording did not:

- **A PEER close is not this defect.** The sink keeps accepting until it learns;
  every peer arm returns. The window that matters is our OWN raw socket.
- **The failure is worse than "throws up".** It reaches the ROOT zone and ends
  the isolate — a crash, not an exception a caller mishandles.
- **Neither candidate guard can see it.** The crashing row reads `isClosed
  false` AND `closeCode null`: within one turn nothing observable has changed.

## Mechanism

`WebSocketSink.add` hands the bytes to a StreamController; the real `sendBytes`
runs a microtask later, inside the zone `AdapterWebSocketChannel` was
constructed in:

```
_StreamSinkImpl.add            <- throws Bad state: StreamSink is closed
IOWebSocket.sendBytes
AdapterWebSocketChannel.<fn>
_RootZone.runUnaryGuarded      <- root zone
_GuaranteeSink.add
RpcWebSocketChannel.send
```

So the throw is not on the caller's stack at all. This is B-35's shape, one
dependency over.

## After

n/a — nothing was fixed, and the reason is measured rather than argued.

**`try { _ws.sink.add(data); } catch (_) {}` was applied and re-run: the crash is
identical.** So was a `runZonedGuarded` around the call site — the probe's own
arm runner is one, and the error still reached the root zone.

What DOES work, also measured: constructing the `WebSocketChannel` inside
`runZonedGuarded`. That arm returns normally and the construction zone's handler
receives the error. The construction zone decides where the throw lands, which
makes it fixable at the library's own entry points and unfixable for a
user-supplied socket.

## Canary

n/a for a fix that was not shipped. The characterisation test carries the
equivalent: three GUARDs pinning what is NOT broken — a live send, a send after
our own `close()`, and a peer close — so the witness cannot pass for a channel
that simply always fails.

## Gate

`fvm dart test` in rpc_dart_websocket: `+148`, including the four new
characterisation tests. `melos run analyze` SUCCESS over 21 packages plus
rpc_dart_wasm; `melos run format:check` SUCCESS; `melos run license:check`
1352/1352. No `lib/` code changed.

## Not fixed

All of it, deliberately, and the reason is a behaviour decision rather than
cost: zone-guarding construction captures every async error from that channel's
internals, not only send failures, so errors that currently surface to the
application would start being rerouted. B-39 carries the three options, the
recommendation, and both refuted fixes by name so they are not retried.

**It is the same decision B-35 is waiting on**, one dependency over, and the two
are worth deciding together.

## Links

Lens `../lenses/RPC-13-unhandled-async-error.md`, eighth application.
Bench `../probes/P-49-send-into-a-dead-socket.md`, new.
Lead `../backlog/archive/B-39-websocket-send-throws-into-the-root-zone.md`, new; sibling
of `../backlog/B-35-finish-throws-into-the-zone.md`.
Round `../rounds/353-reported-not-fatal-was-half-true.md`, whose fixture hit this
first and left it named.
Catalog shape U-17.
