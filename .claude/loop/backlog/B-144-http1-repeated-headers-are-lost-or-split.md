---
status: closed (round 540)
round: 540
commit: 7fe7351c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-173
reason: "both halves CONFIRMED. The request half is FIXED — values are joined with the delimiter the response side already splits on. The response half is split to B-200, because both ways of fixing it change what applications observe"
---

# B-144 — HTTP/1.1: repeated headers are last-wins on requests and every response header is split on commas

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`request.headers[name] = value` keeps the last duplicate; the response side splits EVERY header on `,` — `date` becomes two entries and a foreign `grpc-message` containing a comma (legal per spec) is cut; the responder never splits shelf's comma-joined repeats.

## The shape

Caller `packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:344-350, 436-467`; responder
`rpc_http_responder_transport.dart:267-270`.

## Why it matters

Metadata differs from what was sent, in both directions.

## What round 540 measured

```
  half one — two values of `x-tag` on the request
    the server received: [second]

  half two — every header the caller ended up holding
    date                   2 value(s): "Mon" + "29 Sep 2026 12:00:00 GMT"
    www-authenticate       2 value(s): "Basic realm="one" + "two""
    content-type           1 value(s): "application/grpc+proto"
    grpc-status            1 value(s): "0"
```

Bench `../probes/P-173-do-repeated-metadata-values-survive.md`. Both halves CONFIRMED; the
single-value rows are the control for the second.

## Fix — the send half

"Join on send", as the sketch says: values grouped by name and joined with `,`, the delimiter
PROTOCOL-HTTP2 names and the one the response side already splits on. Half one now reads
`[first,second]`. RPC-08's shape exactly — one direction implemented the rule the other assumed.

## The receive half went to B-200, and the sketch's rule is not available

"Split only custom keys, never `grpc-message` or standard headers" needs a way to tell a custom
key from a standard one, and the wire carries no such marker — it needs a maintained list of
standard fields, whose every gap is this defect again. The alternative is to stop splitting, which
is spec-conformant and changes what every caller observes. Filed for the owner.

`grpc-message` is a non-issue either way: it is percent-encoded over `ALPHA / DIGIT / - . _ ~`, so
a conforming peer cannot put a comma in it, and the code already records that.

## Owner decision

—
