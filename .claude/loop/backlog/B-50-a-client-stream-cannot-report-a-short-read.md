---
status: open
round: 369
commit: 5a22ff67
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/core/headers.dart]
probe: P-60
reason: owner decision — the fix changes what goes on the wire for every client-stream call, and the config's standing requirement is to ask before a trade of that kind
---

# B-50 — a client-stream caller cannot tell a full read from a partial one

Measured (P-60), 17 messages sent, three controls alongside:

```
                    sent  handler got  caller told
shortRead            17        3       OK
shortHold            17        3       OK
fullRead  (control)  17       17       OK
throws    (control)  17        0       RpcStatusException
```

A handler that stops reading (`break`, `take(n)`, "I have seen enough") answers
`OK`, **byte-identical to the answer for a full read**. No log line on either
path. Server-stream does not have this: its consumer cancelling stops the
handler, which is the correct answer.

## Why it matters here specifically

The owner's use for client-stream is **resumable upload of large, CDC-chunked
files**, where re-sending the whole file is the cost being avoided. A caller that
is told `OK` over 3 of 17 chunks records the file as uploaded. That is the same
class of failure round 366 chased in a consumer's blob uploads, arrived at from
the opposite direction.

## The design question, and the part that is NOT the library's

**Resumption is the application's, and the place for it already exists.** The
library knows exactly one thing: how many messages it handed the handler. It does
NOT know how many the handler COMMITTED — a handler can be given 17, write 3, and
fail. A library-side "accepted" count would therefore look authoritative and not
be one. A client-stream already has a response message, and `nextOffset` /
`acceptedChunks` belongs in it, because only the handler knows what is durable.

**Honesty of the status IS the library's**, and is the one thing missing. Note
that turning a short read into an ERROR is the wrong shape for this use case: an
early answer is USEFUL during an upload ("I already have this chunk, stop
sending"), and failing it would break a legitimate pattern. What is needed is a
SIGNAL, not a refusal — a trailer such as `x-rpc-requests-consumed`, surfaced to
the caller, so `OK, consumed=3` is distinguishable from `OK, consumed=17`.

A mid-upload disconnect is already reported honestly (round 368 EC2: the caller
gets `RpcStatusException`), and "how much do you have" after one is an
application round trip — S3 multipart's ListParts, tus's HEAD — not a transport
concern.

## The second half: a counter nobody reads

`RpcResponderStreamState.droppedRequests` documents itself as

> Zero on every healthy call. The pipeline reads it when the call ends, so a
> handler that was fed less than the peer sent cannot finish quietly.

`grep` over the whole workspace returns the declaration and two increments and
**no reader**. Neither of P-60's two paths reached it at all (0 `DROPPED` records
on both, including the arm that holds the stream state alive for 400 ms). So the
promise is false, and the counter may additionally be dead. This half is a
rule-one divergence and is not a behaviour trade — but establishing whether ANY
path reaches it needs a third bench, and round 369's probe budget (3) was spent.

## Owner decision

What is being asked: whether a client-stream call whose handler read fewer
messages than the peer sent should stay indistinguishable from a full read.
Options, in the order this record argues them: a consumed-count trailer surfaced
to the caller (does not break early answers); a non-OK status (breaks them); or
leave the behaviour and delete the false promise on `droppedRequests`.
