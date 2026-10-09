---
status: closed (round 413) — the status half fixed; the unwrapper is routing only
round: 409
commit: fd70f59d
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: none yet — the dead-code fact is a complete sweep; what has no number is the user-visible cost
reason: bench — the reading is certain and the IMPACT is not, and the fix is a choice between restoring a design and deleting it, which needs the number first
---

# B-62 — the envelope nobody unwraps

> **Closed in round 413 by a third option neither of the two below describes.**
> This lead weighed "restore `filterStreamEvents`" against "drop the envelope"
> and called it even, because both are about ROUTING and the envelope is what
> separates a per-stream error from a connection-fatal one.
>
> Round 412 then gave every library error the status that fits, and the envelope
> — a plain class — started destroying all of it: `wireStatusFor` is default-deny,
> so a wrapped `RESOURCE_EXHAUSTED` reached the peer as INTERNAL "Internal
> server error". So it now `extends RpcStatusException`, deriving its status
> THROUGH `wireStatusFor(error)` rather than copying the inner's fields — which
> is what keeps a foreign inner redacted. `streamId` and `error` untouched, so
> routing is unchanged, and no measurement was needed to choose.
>
> **What remains is only the missing call site**, and it is no longer urgent:
> an envelope reaching a broadcast consumer is now classifiable, so the absent
> unwrapper costs precision rather than correctness.

`RpcHttp2StreamError` is not an error, it is an ENVELOPE. Its own doc says so:

> per-stream errors are added as [RpcHttp2StreamError] envelopes.
> [filterStreamEvents] then re-throws the inner error only on the matching
> stream's subscriber.

The envelope is created in production twice — `rpc_http2_caller_transport.dart:1555`
and `rpc_http2_responder_transport.dart:979`, both inside `_emitStreamError`.

**`filterStreamEvents` has no production call site.** Every reference in the
repository:

```
lib/  rpc_http2_common.dart:179   its own doc comment
lib/  rpc_http2_common.dart:197   the declaration
test/ http2_hardening_test.dart   x5, against a hand-made StreamController
CHANGELOG.md:158                  describes it as the mechanism
```

So the unwrapper is exercised only in isolation, by the test named "BUG B:
per-stream error isolation". Nothing in the library calls it, and consumers of
`incomingMessages` therefore receive the raw envelope.

## Why that is not merely dead code

`wireStatusFor` is DEFAULT DENY — round 408's subject. An envelope is not an
`RpcException`, so it takes the deny branch: whatever the INNER error was, the
peer is told INTERNAL(13) "Internal server error". The envelope hides its
contents from the one function whose job is to decide what may be forwarded.

Per-stream routing does not depend on it either: both transports already keep an
`RpcStreamRouter` and call `_streams.addError(streamId, error, stackTrace)` with
the RAW inner error beside the enveloped broadcast add. So the envelope's only
consumer is the broadcast, and the broadcast has no unwrapper.

## Why it is filed rather than fixed

The fix is a choice between two opposite directions, and picking needs a number
neither has:

```
option                         consequence
wire filterStreamEvents into   restores the documented design; adds a
  getMessagesForStream         transform to a path RpcStreamRouter already
                               serves, so it may be redundant twice over
drop the envelope, add the     the broadcast then carries a classifiable error
  inner error directly         and wireStatusFor can see it — but connection
                               fatal errors already go unenveloped, so the two
                               kinds would become indistinguishable, which is
                               what the envelope was introduced to fix
```

The measurement that decides it: what a caller is told today for a stream-level
transport error that is NOT a framing violation — the framing path answers the
peer separately (round 397), so it masks this one.

## Owner decision

None needed. This is a bench problem.
