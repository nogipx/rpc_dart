---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**]
scope: [websocket]
---

# C-09 — Half-close racing the trailers

Can a client's half-close, racing the server's reply, make a SUCCESSFUL call
report UNAVAILABLE? Through the ordinary path, no: the responder puts the status
and the end flag in ONE frame. A half-close sweep over six delays (0-5000 us),
60 iterations each: **360/360 OK**.

The split shape DOES report truncation, and that is correct: a raw peer sending
DATA-with-end and then trailers gets `status 14`; trailers-carrying-end give
`OK`. gRPC agrees, and being lenient would mean keeping the stream open after
the end flag — exactly the ordering trap that silently lost data once.

The accepted cost is written into the test: a peer using the split shape gets a
repeatable status on a call that already finished.

## Control

The split shape gives status 14 and the merged one gives OK: the difference is
in the frame shape, not in a race.
