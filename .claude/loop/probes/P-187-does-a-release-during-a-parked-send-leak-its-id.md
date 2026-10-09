---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b184_halfclosedlocal_leak.dart
round: 565
commit: 4acd6833
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
status: valid
---

# P-187 — does a release landing during a parked send leak its stream id?

## Why it exists

B-184's last item needed a release to land *while* an `endStream: true` send is parked on
the peer's window. Round 564 tried it against a real server and could not schedule it, then
concluded no drivable shape fills the map at all.

**The window is the thing that has to be owned**, and a real gRPC server will not hold it
closed on cue. So the peer here is hand-rolled HTTP/2 frames: SETTINGS with
`INITIAL_WINDOW_SIZE=64`, which makes the second send park, and a RST_STREAM emitted at a
chosen moment.

## The harness

A raw `ServerSocket` that completes the handshake and nothing more — the idiom
`reset_stream_releases_its_pump_test.dart` already uses. Three frames are written by hand:
SETTINGS (window), WINDOW_UPDATE (open it), RST_STREAM (CANCEL).

Two sends per arm, because the pump checks `_paused` BEFORE adding: the first fills the
64-byte window and pauses the sink, the second parks. The arm records whether the send was
still parked when the reset landed, what the parked future did, and
`health().details` for `activeStreams`, `halfClosedLocal` and `outgoingPumps`.

Four arms:

- **WITNESS** — RST_STREAM while the `endStream` send is parked.
- **CONTROL** — WINDOW_UPDATE first, so the send completes before the reset.
- **REACH** — the witness, then `releaseStreamId`, to price the leak's lifetime.
- **STACK** — the same race through `RpcCallerEndpoint`, to ask whether the library's own
  stack can leave it behind.

## The numbers (round 565)

Before:

```
WITNESS   parked=true threw=null
    while parked  {activeStreams: 1, halfClosedLocal: 0, outgoingPumps: 1}
    after reset   {activeStreams: 0, halfClosedLocal: 1, outgoingPumps: 1}
CONTROL
    window open   {activeStreams: 1, halfClosedLocal: 1, outgoingPumps: 1}
    after reset   {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 1}
REACH
    before release  {activeStreams: 0, halfClosedLocal: 1, outgoingPumps: 1}
    after release   {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 0}
STACK
    after reset     {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 0}
```

After:

```
WITNESS
    after reset   {activeStreams: 0, halfClosedLocal: 0, outgoingPumps: 1}
CONTROL
    window open   {activeStreams: 1, halfClosedLocal: 1, outgoingPumps: 1}
```

## Extended in round 568 — the wire, and all seven maps

Two additions, neither of which changed an existing arm:

- **a DATA-frame scanner on the server socket**, walking the 9-byte frame headers, because the
  transport's own maps cannot say whether a payload reached the peer. `WITNESS [(64, false)]`
  against `CONTROL [(64, false), (453, false), (517, true)]` is what established that a parked
  send reporting success had put nothing on the wire;
- **all seven per-stream maps** instead of three, which is what showed `outgoingPumps` to be the
  only one the inline release leaves behind.

```
round 568, before      WITNESS  threw=null   outgoingPumps 1   wire [(64,false)]
round 568, after       WITNESS  threw=RpcStatusException
                                outgoingPumps 0   wire [(64,false)]  unchanged
                       CONTROL  threw=null   wire unchanged, all three frames
```

## Measures

Set sizes read off the transport's own `health()` — `_halfClosedLocal.length` and its
siblings — not a bench counter. Plus two facts about the parked send: whether it was still
parked when the reset landed, and whether it returned or threw. Since round 568, also the DATA
frames the server actually read.

## Control

**The CONTROL arm differs by one frame**: a WINDOW_UPDATE before the RST_STREAM, which lets
the parked send finish first. Same SETTINGS, same metadata, same two sends, same reset. It
read 0 where the witness read 1, so the rig can tell the two orders apart.

**Its `window open` row is the load-bearing one**, and it is why this bench is not round
564's. `{halfClosedLocal: 1}` while the stream is still active proves the add site is
REACHED — so the witness's 0 after the fix is the guard working, not a map nothing fills. A
witness without that row cannot be distinguished from a void arm (`L-15`).

**REACH is the control on severity**: a later `releaseStreamId` removes the entry (and the
pump), so the leak lasts until the id is released rather than for the connection's life.

## What it establishes, and what it does not

Establishes the third of B-184's claims: one entry per reset stream, held on a stream
`activeStreams` no longer knows about, and that `_activeStreams.containsKey` on the re-add
removes it without touching the benign path.

Establishes that **the leak is not reachable through `RpcCallerEndpoint`** — the STACK arm
reads 0 both before and after, because the pipeline releases the id when the call ends. The
exposure is a direct user of the transport, which is public API.

Since round 568 it DOES measure the wire, and the answer is that the payload never left: the
server read `[(64, false)]` against the control's three frames.

Does NOT cover `_waiters` being overtaken by a new `add`, B-184's other unmeasured item.

## Reading

rpc_dart_http2 — four arms around one race: a peer RST_STREAM landing while an
`endStream: true` send is parked on the window. `WITNESS halfClosedLocal 1 /
CONTROL 0 / REACH 1 then 0 after releaseStreamId / STACK 0 through
RpcCallerEndpoint`. **The window is owned by the rig** — hand-rolled SETTINGS
with `INITIAL_WINDOW_SIZE=64`, because no real server holds a window closed on
cue, which is what round 564 could not arrange. **The control's load-bearing
row is `window open halfClosedLocal: 1`**, taken between the grant and the
reset: it proves the add site is reached, so the witness's 0 after the fix is
the guard working rather than a map nothing fills (`L-15`). Two readings it
did not vary are `B-221`: the parked send returns `threw=null` after the
reset, and the pump survives it
