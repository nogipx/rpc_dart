---
round: 491
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-05
bench: P-130 — new
commit: yes
severity: S2
---

# Round 491 — the call ended and the request did not

## Target

B-100, seventh in the audit's rank and the last of its HTTP/1.1 run. Taken in
sequence, and the third round in this file — which is why it went quickly: the
rig from 489 and 490 needed only a middleware added.

Lens RPC-05 — a limit charged or RELEASED at the wrong point of the lifecycle.
Its usual subject is an admission slot; here the thing released is a whole HTTP
request, and releasing it is what fails to happen.

## Hypothesis

`releaseStreamId` removes `_pending[id]` without completing its completer, and
the shelf handler is awaiting that completer, so every stream torn down before
it answered leaves an HTTP request open. Refuted if some other path completed
it, or if shelf timed the request out on its own.

## Before

```
                                 arrived  answered  pendingRequests
handler ignores its token           1        0            0
handler cooperates (control)        1        1            0
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b100_release_hangs.dart`

Counted around `responder.handler`, so `answered` means the future the shelf
server awaits actually completed. **The caller cannot serve as the instrument**:
it reports `RpcDeadlineExceededException` in both arms, its own deadline having
fired regardless of what the server did.

## Mechanism

The pipeline's deadline reclaim cancels the handler's token and, two seconds
later, calls `_cleanupStream` — deliberately without a trailer, because the peer
reaches the same deadline and a trailer would race its local error. That
reasoning is about the STATUS; it left the HTTP exchange with no ending at all.
A handler that ignores its token is exactly the case the reclaim exists for, so
the ordinary way in is the path designed for the worst handler.

`health()` reads `_pending`, which the reclaim has already emptied, so the
`pendingRequests: 0` in both arms is a second finding: a drain polling it sees an
idle server with a response still unwritten.

## After

```
handler ignores its token           1        1            0
```

`releaseStreamId` completes a still-pending response with CANCELLED in ordinary
response headers. CANCELLED rather than DEADLINE_EXCEEDED because the method
cannot know why the stream was released — and the peer that set a deadline has
already reported one locally.

## Canary

`if (pending != null && !pending.completer.isCompleted && 1 < 0)` — the WITNESS
fails with `Expected: <1> / Actual: <0>`, "the shelf request is awaiting a
completer nobody completed, so it stays open until the client gives up". The
CONTROL and the GUARD stay green.

The GUARD is the one that matters for this fix's shape: an ordinary call must be
answered exactly ONCE. `_flushResponse` removes the entry before
`releaseStreamId` can see it, so the two cannot both fire — and a second
completion would throw `Bad state: Future already completed` into the pipeline
rather than failing visibly here.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**`health()` still cannot see an unanswered response**, because the entry it
counts is gone by then. After this fix there is nothing left unanswered for it to
miss, so the blind spot has no defect behind it today — but it is a
one-direction inference, and a future path that drops a pending entry without
completing it would be invisible the same way.

The handler keeps running after its stream is released. Same absence as B-97 and
B-98: no reset on this transport.

## Links

Lens RPC-05. Bench P-130 (new). Lead B-100 (closed). Rounds 489 and 490 are the
other two in this file; the reclaim's no-trailer decision is
`responder_pipeline.dart`'s and is unchanged.
