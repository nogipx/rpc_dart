---
round: 902
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-04
bench: none — the witness is the regression test itself, arms in one file
commit: yes
severity: S2 — "a limit that is off but still bounds"
release: changelog
---

# Round 902 — a wrapped connections stream is warned about

## Target

B-312, opened by round 901's sibling sweep: the same `is` shape as RPC-04 on
`RpcWebSocketServer`'s connections stream. Taken next because it was the
fresh, unmeasured half of the round before.

## Hypothesis

`RpcWebSocketServer.start` hands its policy to the frame guard only when the
connections stream `is IRpcWebSocketServerPolicyTarget`. Wrapped with `.where`
it is not, so a limit raised on the server alone stays off the guard, and a
message between the default and the raised limit is dropped. Fails if the
wrapped stream delivers it like the bare one.

## Before

```
server limit 32 MiB, message 20 MiB    runs  result
bare stream                              3   delivered
CONTROL policy passed to the stream      3   delivered
stream wrapped with .where((_) => true)  3   RpcStatusException(14): WebSocket
                                             connection failed with code 1002
```

Probe: `packages/transport/rpc_dart_websocket/test/the_server_policy_reaches_the_frame_guard_test.dart`

## Mechanism

RPC-04. The guard acts at the upgrade, before the server sees a connection,
and its ceiling starts at the default `maxChannelFrameBytes`; only the
server's hand-off raises it. A wrapped stream is an SDK `Stream`, which
carries no method, so the hand-off never happens. Unlike round 901 a member
cannot fix it: the server cannot tell a wrapped guarded stream from a source
of another kind that has no guard at all.

## After

Owner's choice of three (warn, throw, document): the server logs one warning
at start when its stream cannot take the policy and its frame limit is above
the default, naming `policy:`, `allowUpgrade` and `onConnectionOpened`. The
`rpcWebSocketConnections` doc and the README's `policy` row say to hand the
stream over as it is.

```
arm                                  warnings  message
wrapped, server limit 32 MiB             1     dropped (14, close 1002)
wrapped, default limit                   0     --
bare, server limit 32 MiB                0     delivered
CONTROL policy passed to the stream      --    delivered
```

## Canary

- The warning switched off: "WITNESS: a raised limit is warned about once"
  red; the other 5 green.
- A once-only flag dropped: still green. A restart returns before the
  hand-off, on the subscription it kept, so the flag was dead code; removed,
  and the "once over two starts" assertion stays as the guard of that.

Restored: `+6`.

## Gate

`analyze`, `test:unit:quiet --no-select`, `format:check`, `license:check`,
`api:check`: green.

## Siblings

- websocket: fixed here.
- http: n/a -- the server binds its own socket and takes the policy in its
  constructor; no connections stream is handed in.
- http2: n/a -- the same: its own socket, the policy in the constructor.
- channel: n/a -- no server and no upgrade; the channel transport is built
  over a channel the caller already has.
- isolate: n/a -- no stream of connections; one isolate, one transport.
- wasm: n/a -- in-process, no connections stream.
- caller: n/a -- the guard sits in the server's upgrade.
- responder: fixed here -- the server is the responder side.
- (not a group member) socket: n/a -- `RpcSocketServer` binds its own socket
  and takes the policy in its constructor.

## Not fixed

A wrapped stream still drops the larger message; the warning makes it loud,
not right. The owner chose not to throw, since a source of another kind is
entitled to the larger limit.

## Links

RPC-04, B-312.
