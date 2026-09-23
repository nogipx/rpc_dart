---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: —
reason: cost — split out of B-70 item 24; the copies are near-identical and no drift has been shown to bite
---

# B-84 — three cleanup blocks, each clearing a different subset

`rpc_http2_caller_transport.dart` tears a stream down in three places, over a
shared core of `_streamParsers` / `_initialHeadersReceived` / `_halfClosedLocal`
/ `_reservedStreams` / `_statusReceived`, and each adds something the others do
not:

```
  :788   + _fcForget
  :933   + _streams.remove
  :1180  + _streamSubscriptions.remove
```

**The counts in the original sweep were wrong** — it claimed 5 caller blocks and
3 responder blocks; the re-read found 3 and 4. The shape is confirmed, the
arithmetic was not, and the corrected numbers are recorded here so the next
round does not re-derive the old ones.

This is the weakest of B-70's remainder and is filed at its real strength: three
near-copies where no divergence has been shown to cause anything. RPC-25
declines cosmetic unification, so the bar is the `## Ask` — if these three were
one, whose behaviour would the shared version have, and which of the three would
that CHANGE?

Each of the three extras is a plausible omission in the other two:
- does a stream torn down at `:933` or `:1180` leave flow-control state behind
  (`_fcForget` not called)?
- does one torn down at `:788` leave a live subscription?

Those are two measurable questions and they are the round. If both come back
clean, this closes as a negative in `checked/` — which is a real result and
should be written rather than left open.

## Owner decision

—
