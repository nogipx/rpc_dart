---
refines: U-16
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the client writes the request and awaits the reply on one channel
breaks: a hang that never ends.
applied: []
status: confirmed (round 168, off-journal)
---

# RPC-09 — A call deadline that sits below the write

## Shape

The client writes the request and waits for the reply in sequence, while a
server that refused on size stops reading.

## Detector

Places where an `await` on the send precedes waiting for the reply; deadlines
guarding a completer the code may never reach.

## Ask

Does the deadline fire at all? If not, what blocks earlier?

## Evidence

The send parked in the flow-control window while the refusal sat unread in the
same stream.
