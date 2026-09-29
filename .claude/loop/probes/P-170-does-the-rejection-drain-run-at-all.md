---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b141_reject_drain.dart
round: 537
commit: 6268a40a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
---

# P-170 — does the rejection drain run at all, and does the body read really stop?

## Why it exists

B-141 makes two claims about the same file and they need different instruments. One is about a
library rule (`Request.read()` twice), which can be asked of a bare shelf `Request` in three lines.
The other re-opens a question C-31 answered in round 273, so it is re-measured rather than cited —
RPC-15.

## The harness

Half two constructs a shelf `Request`, reads it, reads it again, and reports what happened.

Half one drives a raw socket that promises a 4 MB body and sends five bytes, against the REAL
`RpcHttpResponderTransport` behind `shelf_io`, and reads two things: the status line the peer
receives, and how much the client can still push afterwards.

**The first version of half one used a hand-written stand-in server and reported
`closed with nothing` where the transport reports `408`.** The two differ in exactly the detail
under test — whether the body is still attached when the response completes — so the stand-in
measured its own author instead of the code. Recorded because the wrong answer was plausible.

## The numbers (round 537)

```
  half two — a second read() on one shelf Request
    StateError: The 'read' method can only be called once on a shelf.Request/shelf.Response object.

  half one — a slow body, 4 MB promised and 5 bytes sent
    arm                     the peer saw                  wrote after (KiB)
    bodyReadTimeout 500ms   HTTP/1.1 408 Request Time-out 384
    CONTROL no timeout      NOTHING within 6s             4096
```

## Measures

Whether a second read throws; the status line the peer receives; and the KiB the client can push
once answered, which is what says the server stopped reading rather than merely answered.

## Control

**The undeadlined arm.** Without it the 384 KiB is just a number: the same rig against a server that
IS still reading takes 4096 KiB and answers nothing at all.

## What it establishes, and what it does not

Establishes: `_reject`'s drain THROWS on the 408/413/400 paths, because the body reader has already
consumed the request — the lead's second half, confirmed as a fact. And it reproduces C-31 at today's
sha: the timeout does stop the read, the peer gets its 408, and the 384 KiB matches round 273's number
exactly.

Does NOT show the swallowed StateError causing harm. The status arrives regardless, because the body
is still attached when the response completes and dart:io detaches it then — which is C-31's own
explanation, now confirmed twice.

Does NOT cover `close()`'s drain, which the lead also names.
