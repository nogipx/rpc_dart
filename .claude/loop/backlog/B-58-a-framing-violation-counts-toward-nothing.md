---
status: open
round: 397
commit: d9d96cd2
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: P-84 measures the release half; the COST of a per-connection grind — one stream, N refused frames — has no number
reason: behaviour decision — one catch covers a resource limit the sender can retry and a malformed frame it cannot, and counting both closes connections on legitimate clients that merely misjudged a size limit
---

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

The cost side has no number yet. P-84's hostile arm is five bytes per stream;
the question here is the per-CONNECTION grind — one stream, N refused frames —
and what it costs the server now that each refusal also tears the call down and
releases. Measure that before deciding the backstop is needed.

## Owner decision

Needed, and only on the second branch: should `closeOnProtocolError` fire for
malformed framing? The field's own doc says "a protocol violation", and whether
a frame this transport cannot decode counts as one is a contract question, not a
measurement. The resource-limit branch needs no decision — it must not count.
