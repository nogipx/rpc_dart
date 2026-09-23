---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
probe: —
reason: cost — split out of B-70 item 21; needs a real socket and a real RTT, because an in-memory pair never parks
---

# B-74 — only one of four send paths waits for a credit-parked frame

`channel_transport.dart` has four send paths: `sendMetadata` (`:442`),
`sendMessage` (`:461`), `sendDirectObject` (`:509`), `finishSending` (`:532`).
**Only `finishSending` consults `_finishedStreams` (`:537`) and awaits a
credit-parked send (`:550`)**, under a comment explaining that an end-of-stream
carries no payload so nothing meters it.

`sendMetadata(endStream: true)` goes straight to `_channel.send` and calls
`_markFinished` AFTER — so a trailer can overtake a DATA frame still parked in
`_fcAwaitCredit`.

**Same class as round 366**, which came in from a real user: an end-of-stream
that sailed past a waiting message, seen as
`Declared length 2442197 does not match received 524288 bytes` fifteen times
with no reconnect in the logs. 366 fixed `finishSending`; this is the same rule
missing from the sibling that can also end a stream.

**The bench is the hard part and P-58 already solved it**:
`RpcChannelTransport.pair()` answers "never parks" in every row, because the
parked state needs a real socket and a real RTT. Reuse P-58's shape, repeat its
control first, and drive the ending through `sendMetadata(endStream: true)`
rather than `finishSending`.

Trap recorded by 366 and still true: the credit gate admits on `credit > 0`, not
on whether the message FITS, so a 256 KiB frame passes a 64 KiB window and the
SECOND frame is the one that parks. Reading the constants predicts the opposite.

## Owner decision

—
