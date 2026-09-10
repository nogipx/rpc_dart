---
refines: U-24
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/core/**]
applies: sibling implementations of one interface each hand-roll the same helper
breaks: "wrong result: the copies drift, and the one that drifted is the one nobody compared."
applied: [308, 309, 310]
status: confirmed (round 308)
---

# RPC-25 — The same abstraction, four times

## Shape

Several classes implement the same interface, in different packages, written at
different times. Each needs a helper the interface does not provide, so each
writes one. The copies start identical and then DRIFT — and because no file
imports another, nothing brings the difference to anyone's attention.

This is not "duplicated code" as a tidiness complaint. The defect is the drift,
and the drift is invisible by construction: the four copies are in four
packages, and a reader has all of one of them on screen.

## Detector

1. **Find a field every sibling declares.** The name is usually identical,
   because they were copied:
   `grep -n "_streamControllers" packages/transport/*/lib/**`
2. **Read the METHODS around it in each sibling, side by side.** Not the field —
   the operations. Four copies of a five-line method are cheap; four copies that
   disagree are the finding.
3. **Diff them by behaviour, not by text.** Ask of each copy: what does it do
   that the others do not, and is that a deliberate specialisation or a slip?

## Ask

If these four were one, which copy's behaviour would the shared version have —
and which copies would that CHANGE?

Every copy the answer changes is a drift, and each is either a latent defect or
an undocumented specialisation. There is no third category.

## Evidence

**Round 308, the per-stream router.** `rpc_http_caller_transport`,
`rpc_http_responder_transport`, `rpc_http2_caller_transport` and
`rpc_http2_responder_transport` each carried a `Map<int, StreamController<...>>`
plus its own `getMessagesForStream`, `_emit`, `_emitError` and close loop.

    the four copies                          121 lines
    the shared RpcStreamRouter                57 lines of code
    transports, net                          -64 lines

The drift step 3 asks for found one, and it was a real defect rather than a
style difference. `rpc_http2_caller_transport.getMessagesForStream`:

```dart
final existing = _streamControllers[streamId];
if (existing != null) return existing.stream;          // NOT metered
...
return _fcMetered(streamId, ctl.stream);               // metered
```

A repeat call for the same stream returned the stream WITHOUT flow-control
metering, so that consumer never discharged its budget: `_fcOutstanding` only
climbs, and the call is eventually refused at the window for bytes it did
consume. Its own responder sibling, twenty lines of near-identical code in
another file, meters both paths.

**Nothing could have caught it.** The two files never import each other, the
analyzer sees two correct methods, and every test passes because the second
`getMessagesForStream` call is the uncommon path. It is visible only when the
four are put side by side — which is what the extraction forces.

**Round 309, the drain loop.** Three servers polling a count to zero, 65 lines.
The drift was in the LOGGING, not the logic — the copies agreed on what to do
and disagreed on what to say:

                     start log   success log
    websocket        info        (none)
    http             debug       (none)
    http2            info        info "Drain complete"

An operator watching an HTTP/1.1 deploy at the default level saw nothing, and on
two of three servers the ONLY line a drain ever produced was "budget expired,
closing anyway" — so success was signalled by an absence. **Look at what the
copies SAY, not only at what they compute.**

## "It does not apply here" is a claim, and it needs the grep

Round 309 declared `rpc_dart_isolate` out of scope by REASONING: one transport
in two platform variants, SendPort against Worker, different mechanisms, no
siblings. Round 310 ran step 1 instead and found `_incomingCtl`, `_messageSub`,
`_closed` and `_onClose` declared identically in both — the same
`IRpcMultiplexedChannel` lifecycle twice, with a byte-identical `close()` — and
two drifts in it, one a live defect.

**Different mechanism is not different abstraction.** Two classes can wrap
unrelated transports and still be one lifecycle written twice; the wire format
is a parameter, not the shape. Step 1 asks for a FIELD every sibling declares
because a field name survives that difference where an argument about mechanism
does not.

The lens can legitimately not apply — but only after the grep returns nothing.

## What a no-drift candidate earns

Nothing. Round 309 left `_notify` — eight identical lines in two servers —
unmerged, because step 3 found no divergence and merging would add a public
promise to core to save eight lines. **The bar is the drift, not the line
count.** Record the decision, or the next round reads it as oversight.

**Round 310, the isolate channels.** The remedy is NOT always extraction. The
two variants compile on different platforms and speak different wire formats, so
one shared class would be an abstraction over nothing — but the drift was real
and had to go. **Aligning the copies is a legitimate outcome**: the lens is
about finding the divergence, and merging is one of two ways to end it.

The drifts, both in the web copy:

    send() failure   VM: throws, names the stream, channel STAYS OPEN
                     web: catch (_) { await close(); }
    stream 0         VM: filtered on data/finish, NOT on metadata
                     web: not filtered at all

The first is the defect the VM copy was fixed away from, still live on the other
platform — and its comment says why: unsendable payload is one message's
problem, and closing makes it the whole connection's. The second silently
diverged on which frames are legal on the reserved stream.

## Where to put the shared version

Beside the siblings' existing shared dependency, not in a new "utils" package.
Here that is `rpc_dart`'s `src/core/`, next to `BufferedBroadcastController` and
`RpcMessageParser`, which RPC-24 established are the transport-authoring API
rather than internals — all four transports already build on them.

**A shared helper is a new public promise** (RPC-24), so it is chosen, not
emitted: `RpcStreamRouter` owns the per-stream half ONLY, and each transport
keeps its own broadcast and decides what goes on it. Extracting the broadcast
too would have forced three different error-envelope policies into one class.

## What NOT to merge

The specialisations that are real. All four transports wrap the router
differently and must:

- http2 wraps the returned stream in `_fcMetered`; the http pair does not.
- the http caller reports `_closedDuringCall()` on close, but only for streams
  in flight — which is why `closeAll` takes `Object? Function(int)` and honours
  a null return, rather than one error for everybody.

A merge that erases these is worse than the duplication: it swaps four honest
copies for one class with four flags.
