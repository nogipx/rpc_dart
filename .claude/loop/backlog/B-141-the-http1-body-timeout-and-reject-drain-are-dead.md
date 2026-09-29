---
status: closed (round 537)
round: 537
commit: 6268a40a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-170
reason: "first half REFUTED again (C-31 reproduced at today's sha: the read does stop, the 408 arrives, the same 384 KiB); second half CONFIRMED as a fact and HARMLESS — the drain throws StateError on the post-read paths and the status arrives regardless. Fixed so the transport stops attempting it and stops hiding the error"
---

# B-141 — HTTP/1.1 responder: the body-read timeout does not stop the read, and `_reject`'s drain always fails

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`readBody().timeout()` abandons the future while `await for (request.read())` keeps running; `_reject` then calls `request.read()` a second time, shelf throws StateError, and `catch (_)` swallows it — the 408/413/400 drain never runs, nor does the one in `close()`.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:156-172, 363-370, 410-418, 573`.

## Why it matters

The defect `_reject`'s own doc describes, present; C-31 measured that the read
stops accepting after the 408 — the reader itself is still running.

## What round 537 measured

```
  half two — a second read() on one shelf Request
    StateError: The 'read' method can only be called once on a shelf.Request/shelf.Response object.

  half one — a slow body, 4 MB promised and 5 bytes sent
    arm                     the peer saw                  wrote after (KiB)
    bodyReadTimeout 500ms   HTTP/1.1 408 Request Time-out 384
    CONTROL no timeout      NOTHING within 6s             4096
```

Bench `../probes/P-170-does-the-rejection-drain-run-at-all.md`.

**First half REFUTED again**, and `checked/C-31` reproduced exactly at today's sha — the same 384 KiB
of socket buffer, against a control that takes 4096 KiB and answers nothing. The read does stop.

**Second half CONFIRMED as a fact and HARMLESS.** The drain throws on the 408/413/400 paths, and the
peer still gets its 408: the body is still attached when the response completes and dart:io detaches
it then, which is C-31's own explanation.

## Fix

Not the sketch. Reading through a cancellable subscription is already what both paths do; the problem
was calling `read()` at all after the body reader had run. `_reject` now takes `drainBody`, the three
post-read callers pass false, and the catch narrows so a `StateError` is logged at warning — every
other failure there is the peer's doing, and that one can only be ours.

Behaviour unchanged. What changed is that the transport stops performing an operation it knows will
fail, and stops hiding the error when it does.

## Still open

`close()`'s drain, which the lead names in the same sentence and nothing here looked at.

## Owner decision

—
