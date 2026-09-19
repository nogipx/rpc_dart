---
status: awaiting owner
round: 397
commit: d9d96cd2
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: P-84 measures the release half; the COST of a per-connection grind — one stream, N refused frames — has no number
reason: owner decision — the COST half is answered (round 399: a refusal flood costs the server LESS than the same volume of honest calls, so no backstop is justified on cost); what remains is whether `closeOnProtocolError` should mean malformed framing, which is a question about the field's contract
---

> **Round 399 answered the cost half and it argues AGAINST the backstop.** P-85,
> 2000 operations each on one connection through a byte-counting relay:
>
> ```
> arm            ops     ms    up B/op  down B/op   amp    status
> served        2000    873      164.3      128.0   0.78x   0
> framing       2000    548      134.0      216.0   1.61x   8
> :method GET    300     66      133.0      162.5   1.22x   3
> ```
>
> The server does LESS work per refusal than per honest call, so grinding
> refused frames is a worse attack than simply calling. `:method GET` is the
> sibling site with its backstop, closing the connection after the 256th
> violation — which is what the framing site is missing, and what nothing now
> shows a need for.
>
> The one axis where the refusal is worse is amplification: 1.61x, the only path
> here writing more than it reads. Ablated — `maxHeaderValueBytes: 24`, same
> site (`grpc-status 8`), **216 B down becomes 131 and the amplification goes** —
> so the cause is the parser's diagnostic text, which is the thing that lets a
> client fix its own request. Recorded, not changed.

# B-58 — a framing violation counts toward nothing

Two refusal sites in one file answer a peer and then account for the refusal
differently.

`_answerRejectedStream` — a request refused in its HEADERS — increments
`_policyViolations` against the 256 backstop and honours
`closeOnProtocolError`, so a peer grinding out malformed header blocks loses the
connection. `_answerFramingViolation` — a request refused in a DATA frame — does
neither. Round 397 released the stream on that path; the counting half was left
alone, deliberately.

## Why it was not fixed with the release

The two things the site refuses are not the same kind of event, and one counter
cannot be right for both:

```
error type        what it means                       counting it would
RpcException      a resource limit: message too       close connections on
                  large, buffer overflow, too many    clients that misjudged
                  messages in a chunk                 a size limit
anything else     malformed framing                   be correct
```

An over-limit message is answered RESOURCE_EXHAUSTED precisely because the
sender can correct it and retry — `RpcRetryInterceptor` treats it as transient.
A client configured with a larger send limit than the server's receive limit
hits this on every call, and ending its connection every 256 calls (or
immediately, under `closeOnProtocolError`) is a different contract from the one
the field documents.

So the fix is not "add the counter", it is "split the two branches and count
only the second" — and whether `closeOnProtocolError` should fire for malformed
framing at all is a decision about what that knob means, which is the owner's.

## What a round taking this would measure

~~The cost side has no number yet.~~ **Done in round 399 — see the note at the
top. The answer is that no backstop is justified on cost**, so what is left
below is only the contract question.

## Owner decision

Needed, and only on the second branch: should `closeOnProtocolError` fire for
malformed framing? The field's own doc says "a protocol violation", and whether
a frame this transport cannot decode counts as one is a contract question, not a
measurement. The resource-limit branch needs no decision — it must not count.
