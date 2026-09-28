---
status: closed (round 491)
round: 491
commit: 00e27930
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: P-130
reason: "closed — the witness was built and CONFIRMED it, requests answered 0 of 1 against a control's 1 of 1"
---

# B-100 — releaseStreamId on the HTTP/1.1 responder drops the pending call without answering it

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`releaseStreamId` removes `_pending[id]` and never completes its completer; the deadline reclaim (`_onDeadlineExceeded` → `_cleanupStream`) deliberately sends no trailer, so the shelf handler awaits a future that never completes and the HTTP response is never written.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:440-443`:

```dart
bool releaseStreamId(int streamId) {
  _pending.remove(streamId);
  return _idManager.releaseId(streamId);
}
```

The shelf handler returns `pending.completer.future` (`:422`). The reclaim path:
`responder_pipeline.dart:2089-2112` cancels the token and, 2 s later, calls
`_cleanupStream` without a trailer ("Deliberately does NOT answer with a
DEADLINE_EXCEEDED trailer"). A late `sendMetadata` then finds no pending call and
only logs (`:452-458`).

## Why it matters

Every call whose handler ignores its token past the deadline leaves a shelf
request pending forever: the connection stays open until the client gives up,
and the request object and handler closure stay reachable after that. `health()`
counts `_pending`, so the drain reads zero while those responses are unwritten.

## Witness a round would build

Unary handler that ignores cancellation and sleeps 10 s; caller deadline 500 ms.
After 3 s: does the server-side request future complete? Expected today: no.

## Fix sketch

Complete the completer in `releaseStreamId` (a 200 with `grpc-status` 4/1, or a
503) when it is still pending.

## Owner decision

—

## Closed (round 491) — confirmed, and the second sentence too

```
                                 arrived  answered  pendingRequests
handler ignores its token           1        0            0
handler cooperates (control)        1        1            0
```

The lead's witness design was built as written and read what it predicted. The
instrument has to be on the SERVER: the caller reports
`RpcDeadlineExceededException` in both arms, its own deadline having fired
regardless.

**The lead's `health()` sentence is confirmed too** — `pendingRequests: 0` while
the response was unwritten, because the reclaim had already removed the entry
`health()` counts.

Fixed as the sketch says, with the status chosen: **CANCELLED, not
DEADLINE_EXCEEDED and not 503.** `releaseStreamId` cannot know why the stream was
released, and a peer that set a deadline has already reported one locally.

The guard that earns its place is that an ordinary call is answered exactly ONCE:
`_flushResponse` removes the entry before this can see it, and a second
completion would throw `Bad state: Future already completed` into the pipeline
rather than failing visibly.

Still true, with no defect behind it today: `health()` cannot see an unanswered
response, since the entry it counts is gone by then. After this fix nothing is
left unanswered for it to miss — but a future path that drops a pending entry
without completing it would be invisible the same way.
