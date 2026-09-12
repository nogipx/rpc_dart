---
round: 353
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-19
bench: P-45 — new
commit: yes
---

# Round 353 — "reported rather than fatal" was half true

## Target

The owner's 6.0.0 review list, P0 item 3.

RPC-19, widened. Its Shape is *"a single boolean carries two states that are not
the same"*, and every reader then interprets it in whichever sense suits that
call site. Here the object is not a boolean but an ERROR STREAM, and it carries
exactly two states that are not the same: **the connection is gone**, and **the
peer sent one frame we could not use**. `RpcChannelTransport` reads both in the
first sense. The `applies:` is widened from a flag to any single signal carrying
both, which is what the three instances now have in common.

**Scope counted before the fix.** The class is *every error that can reach
`RpcChannelTransport`'s `onError`, and whether it means the connection is gone*.
Every `addError` on that path, across core and all five transports:

```
site                                              connection gone?
RpcWebSocketChannel, ws stream onError            yes
RpcWebSocketChannel, onDone close-code report     yes -- close() follows
RpcFrameMultiplexedChannel._failChannel (3 sites) yes -- closeForProtocolError
RpcFrameMultiplexedChannel, byte-pipe onError     yes -- forwards the above
RpcFlutterWasmBridge._reportDeath                 yes -- _incoming.close()
RpcChannelTransport._validateInbound              already per-stream scoped
RpcWebSocketChannel, TEXT frame                   NO
```

One site. Everything else that reaches the fan-out either closes the connection
in the same breath or was already scoped to the offending stream.

## Hypothesis

The channel's own comment says the text frame is *"reported rather than fatal,
so the connection stays usable for the binary frames around it"*. The connection
is only one of the things at stake. If the layer above treats any channel error
as connection-level, then "not fatal to the connection" and "not fatal to the
calls" are different claims and only the first was ever checked —
`non_binary_frame_test.dart` asserts on the channel and stops there.

## Before

```
arm          calls completed  outcome                     connection
no text          2 of 2       ok, ok                      alive
text frame       0 of 2       RpcException, RpcException  alive
```

One frame, 2 of 2 calls lost; and 1 of the 7 `addError` sites reaching that
subscription is the one that produced it.

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/text_frame_blast_radius.dart`.
One variable: whether the server interleaves one text frame while two unary
calls are parked in the handler.

`RpcException` is not a status, so it carries no retry semantics at all — a
caller cannot even classify it. One app-level keepalive from a proxy killed
every call on the connection, and the connection stayed up to take more.

## Mechanism

`RpcChannelTransport`'s channel subscription answers an error into every
per-stream controller, deliberately: *"a connection-level failure is the answer
to every call in flight on it"*. That reasoning is right and the premise is
supplied by the channel. The websocket channel sent a plain `RpcException` for
an observation about a single discarded frame — the same shape a dead socket
sends — so the transport amplified it to every live call.

## After

```
arm          calls completed  outcome  connection
no text          2 of 2       ok, ok   alive
text frame       2 of 2       ok, ok   alive
```

`IRpcAdvisoryChannelError`, a marker in core, checked at the one place that
amplifies. The report still reaches the transport's `incomingMessages`, where
both the caller and the responder pipeline log it — which is the whole point of
reporting rather than dropping, and is why no logger plumbing was needed.

## Canary

Two halves, two canaries.

```
the fan-out check removed (`if (1 > 0 || e is! IRpcAdvisoryChannelError)`)
  RpcException: RpcWebSocketChannel: expected a binary WebSocket message,
  got String. ...
the marker removed from the error (a plain RpcException again)
  RpcException: canary: the plain exception, with no advisory marker
  Expected: <Instance of 'RpcWebSocketNonBinaryFrame'>
```

The first fails the witness alone; the second fails the witness AND the
first guard, which is correct — the guard is what checks the report still
arrives. The third guard, a real 1011 close still answering both calls, stayed
green under both: that is the property the fan-out exists for, and an
over-broad fix would have removed it.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` 1343/1343; `melos run test:wasm` `+40`;
`melos run test:web` `+6`. Plus `fvm dart test` in rpc_dart_websocket, `+140`.

**The first `test:unit` run failed and it was NOT called a flake.** `uptime`
read a 1-minute load average of **20.02** — the exact condition `config.md`
names — and `rpc_dart_isolate` and `rpc_dart_websocket` both exited 1 with no
`[E]` line to show for it. Each passed alone immediately after, and the whole
gate passed at load **5.32**. Named, then re-run; the config asks for the naming
because a batch of unnamed failures is indistinguishable from a real regression.

## Not fixed

**The third guard tripped over the owner's item 9 and it is left standing.**
Waking a parked handler after its socket is gone makes it answer into a closed
sink, and `RpcWebSocketChannel.send` calls `_ws.sink.add` with no try/catch, so
`Bad state: StreamSink is closed` escapes through `UnaryResponder.handleMessage`
where nothing catches it. That is item 9 of the review list, due its own round;
this round's fixture simply stops driving the handler after the close, with the
reason written beside it.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` (`applies:` widened
from a flag to any signal carrying two meanings; fourth application).
Bench `../probes/P-45-text-frame-blast-radius.md`, new.
Catalog shapes U-18 and U-01 — the give-away was a comment asserting
deliberateness about half of the question.
