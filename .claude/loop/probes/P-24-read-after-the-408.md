---
file: packages/transport/rpc_dart_http/.dart_tool/probe/read_after_the_408.dart
round: 273
commit: f91dd5d9
paths: [packages/transport/rpc_dart_http/lib/**]
status: valid
---

# P-24 — does the server keep reading after it has answered?

One socket promises a large body, sends five bytes, waits for the answer, and
then writes as fast as the server will take it, deadlining every flush. The
observable is the PEER's send pressure: a server that stopped reading stops
draining our send buffer, so the writes stall inside a few hundred KiB of kernel
buffering. Point it at any "we answered early, is the work still running?"
question on a socket transport.

## Measures

KiB the server accepted after answering, counted at the client, with a 3s
deadline per flush. Not a server-side counter on purpose: the question is
whether the server's read loop is alive, and instrumenting the loop to ask that
changes the thing being asked about.

## Control

`bodyReadTimeout` unset, so `readBody()` consumes until the body is complete.
That arm is what proves the bench can see a READING server — without it, "the
writes stalled" is indistinguishable from a bench that cannot write.

```
arm      bodyReadTimeout  status           took                 pendingRequests
reading  none             NEVER ANSWERED   16384 of 16384 KiB   1
                                           in 49 ms
timeout  500ms            408              384 KiB, then a      0
                                           3s stall (x2 runs)
```

> **The stall is the evidence and it needs a deadline, not a hang.** Every write
> is `flush().timeout(3s)`, so a server that has stopped reading produces a
> number rather than freezing the probe. 384 KiB is the socket's own buffering
> and reproduced exactly across runs.
