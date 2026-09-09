---
round: 240
verdict: FIXED
packages: [rpc_dart]
lens: RPC-20
bench: P-18 — new
commit: yes
---

# Round 240 — the buffer drained into nothing

## Target

RPC-20, never applied in this journal. Weighed against what `next` printed:

- **B-23**, the open continuation, was passed over deliberately. Round 239 left
  21 files, and its own record says six of them need the owner's call on where
  they go — so a round cannot finish the lead, only shrink it again. It stays
  `continuation: yes`.
- **RPC-06** (the plugin's native layers) needs a booted simulator, which an
  unattended round cannot have.
- **RPC-10**'s damage class is "a claim about a fix's blast radius" — below the
  severity bar as a target, though it is what made this round check the
  siblings.
- **RPC-21**, the strongest alternative, already has a clean half in C-06.
- The five stale sweeps have each been swept once; `loop.py yield` says the
  lenses mined out of pre-journal history found a defect on FIRST application
  three times out of three, and RPC-20 is one of the four that had never been
  applied.

## Hypothesis

The isolate transport was fixed for this shape (the lens's own evidence). If the
shape is real, a SIBLING hop has it too: some place where a buffered inbound
stream is drained by something that then re-broadcasts through a controller with
no listener. Falsifiable — every inbound controller in the library might already
buffer.

## Before

The detector's second clause listed every inbound controller. All of them use
`BufferedBroadcastController` — core's `RpcChannelTransport`, http caller and
responder, http2 caller and responder, websocket caller — except one:
`_ReconnectingTransportProxy._msgCtl` in `client_connection.dart`, a plain
`StreamController.broadcast()`. And `attach()` is precisely what drains the
inner transport's buffer.

```
arm                                        frames seen
A  late, through RpcClientConnection            0
B  early, through RpcClientConnection           1
C  late, straight off the transport             1
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/rpc20_proxy_window.dart` (P-18).

## Mechanism

Every transport retains inbound frames until its first listener, and
`attach()` IS that first listener. It forwarded them into a plain broadcast
controller that the application had not subscribed to yet, so the inner buffer
was drained into nothing. The buffering was defeated one hop up — the trap the
lens states in its own words: *a buffering carrier only helps at the hop it is
on*.

The lossy order is the DOCUMENTED one. `RpcClientConnection` is "the
recommended, transport-agnostic way to get auto-reconnect on a client", and
waiting for `RpcClientOnline` before building the endpoint is what its
observable-state API invites. By the time that state arrives, `attach()` has
already run.

## After

```
arm                                        frames seen
A  late, through RpcClientConnection            1
B  early, through RpcClientConnection           1
C  late, straight off the transport             1
```

Same probe, same three arms.

## Canary

`early_frames_survive_the_proxy_test.dart` — with `_msgCtl` switched back to
`StreamController.broadcast()` in place, the witness failed with

    Expected: non-empty
      Actual: []
    the peer greeted before the app subscribed; the proxy dropped it

The second test in the file (subscribe before `connect()`) passed on BOTH sides.
That is the separation that matters: the witness is timing-dependent, so a test
that went red on both would have been measuring "no messages at all" instead.

## Gate

`melos run analyze` SUCCESS (21 members + wasm) · `melos run test:unit
--no-select` SUCCESS (rpc_dart 1414 passed / 1 skipped, http2 196, websocket
134) · `melos run format:check` SUCCESS · `melos run license:check` REUSE
compliant, 1203/1203 files. In the package: `fvm dart analyze lib test` clean,
`fvm dart test -j 8` 1414 passed.

## Not fixed

**The dart2js target could not be run in this environment.** `fvm dart test -p
node` fails at LOAD with `Error: read ENETDOWN` / "Node exited before connecting
to the test channel". Reproduced on code this round never touched —
`test/core/` (7 of 189 files) and `client_connection_test.dart` alone, at load
8.2 — so it is the machine's loopback, not the change. Nothing here is
dart2js-sensitive (no `async*` cancel, no int above 2^53, no clock), but that is
reasoning, not a measurement, and the measurement is owed.

**Only the resilience hop was fixed.** The detector also found
`RpcFrameMultiplexedChannel._incomingCtl` to be a plain broadcast. It is safe
today because `RpcChannelTransport.fromChannel` builds channel and transport in
one expression with no await between — but that safety is an ordering
coincidence in a constructor, not an invariant anything checks, and the class is
public and documented for direct construction. Filed as B-24.

## Links

Lens RPC-20 (first application, now confirmed) · bench P-18 (new) ·
lead B-24 (new) · the sibling map that pointed here is RPC-10 · the shape is
catalog U-11.
