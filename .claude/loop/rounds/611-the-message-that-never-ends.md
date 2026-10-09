---
round: 611
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-18
bench: P-216 — new
budget: probes 3/5, canaries 1/5
commit: yes
release: changelog
severity: S1
---

# Round 611 — the message that never ends

## Target

B-202: on dart:io's WebSocket a message is resident before rpc_dart sees a byte,
so no rpc_dart limit is a residency bound there. The lead asked which limit
actually holds.

## Hypothesis

None does for a message that never finishes: dart:io keeps appending fragments
until FIN, so a peer that never sends one is buffered for as long as it writes.

## Before

```
64 x 1 MiB continuation frames, no FIN, policy 1 MiB    never closed   RSS +34 MiB
256 x 1 MiB                                             never closed   RSS +147 MiB
```

One unauthenticated connection, growing with what it sends. `P-216`.

## Control

`oversized_message_is_refused_test.dart`: whole messages under the policy are
accepted and one over it is closed with 4400. The multiplexer's cap works once a
message is delivered, and the unfinished one is never delivered.

## Mechanism

dart:io's protocol transformer has no message ceiling. It sums fragments into
one buffer until FIN, and `RpcFrameMultiplexedChannel` receives nothing until
then.

## After

```
64 x 1 MiB, policy 1 MiB    closed after fragment 1    RSS +11 MiB
```

`rpcWebSocketConnections` performs the upgrade itself when compression is off
(the default): it writes the 101 (accept key via `package:crypto`, the owner's
choice), detaches the socket, and passes it to `WebSocket.fromUpgradedSocket`
through a `Socket` whose inbound bytes run through `WebSocketFrameGuard`. The
guard reads each frame header and sums declared lengths per message, so the
refusal comes before the payload is read. Past the ceiling it destroys the
socket. The ceiling is the multiplexer's own reassembly cap,
`effectiveMaxBufferedBytes + RpcChannelFrame.headerSize`, from a new `policy:`
parameter that takes the same policy as `RpcWebSocketServer`. One WebSocket
message carries exactly one channel frame, so a larger one would be refused there
anyway. With compression on, dart:io's transformer is still used, already
documented as unsafe.

## Canary

`guard.admit(data) || true`: the witness fails with `Expected: not null,
Actual: <null>` (64 MiB of one message buffered, RSS +50 MiB). The guard's own
arms are pinned in `websocket_frame_guard_test.dart`: fragments are summed, a
final fragment resets the count, a control frame between fragments does not, a
control frame over 125 bytes is refused, the refusal comes from the header
alone, and byte-at-a-time input parses the same.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (rpc_dart +1911,
websocket +257), `melos run format:check`, `melos run license:check` — green.

## Not fixed

The refusal is a destroyed socket, not a 1009 close frame. dart:io writes through
`addStream`, so a frame of our own cannot be interleaved safely. The peer sees an
abnormal closure. B-202's second half, the client's redundant copy of the
metadata bound, stays unmerged on purpose (no failure behind it).

## Links

Lead `../backlog/B-202-a-whole-frame-in-one-chunk-is-resident-before-any-check.md` — closed.
Bench `../probes/P-216-an-unfinished-websocket-message.md` — new.
Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md` — `applied: [..., 611]`.
Tests `packages/transport/rpc_dart_websocket/test/an_unfinished_message_is_bounded_test.dart`,
`packages/transport/rpc_dart_websocket/test/websocket_frame_guard_test.dart`.
