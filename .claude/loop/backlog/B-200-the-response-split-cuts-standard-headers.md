---
status: awaiting owner
round: 540
commit: 7fe7351c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-173
reason: "owner decision — CONFIRMED, and both ways of fixing it change what applications observe: maintain a standard-field list, or stop splitting and let metadata carry the joined value"
---

# B-200 — the HTTP/1.1 response split cuts standard headers in half

Split out of B-144 in round 540, which closed the request half. Measured: `P-173`.

The caller splits EVERY response header on `,`:

```
  date                   2 value(s): "Mon" + "29 Sep 2026 12:00:00 GMT"
  www-authenticate       2 value(s): "Basic realm="one" + "two""
  content-type           1 value(s): "application/grpc+proto"
  grpc-status            1 value(s): "0"
```

`date`'s comma follows the weekday; `www-authenticate`'s sits inside a quoted string. Neither
field's definition permits list recombination, so splitting them is not the recombination the
field provides for — it is a cut through one value.

## What is NOT wrong

**The split itself is right for Custom-Metadata, and the code says why at length.**
PROTOCOL-HTTP2 states duplicate metadata names "may have their values joined with ',' as the
delimiter and be considered semantically equivalent", so splitting is the recombination that
field's definition provides for — and NOT splitting would collapse values the spec calls
equivalent. The request side now joins on the same delimiter, so the two directions agree.

**`grpc-status` and `grpc-message` are unaffected either way**: the status is numeric and
`grpc-message` is percent-encoded over `ALPHA / DIGIT / - . _ ~`, so neither can contain a
comma. The lead that raised this (B-144) claimed a foreign `grpc-message` with a comma would be
cut; a peer sending one is out of spec, and the code already records that.

## Why it matters

A caller reading response metadata sees `date` as two values, one of them `"Mon"`. Anything
keying off a standard field gets a fragment.

## The two fixes, and why neither is a round's to pick

**Keep a standard-field list and never split those.** Precise, and a maintenance burden that
grows with HTTP: every field whose value may contain a comma inside one value has to be in it,
and a missing entry is this same defect for that field.

**Stop splitting; let metadata carry the joined value.** Spec-conformant — joined and repeated
are defined as equivalent — and it removes the list entirely. But an application that today
receives two values for a repeated custom key would receive one, so it changes what every
caller observes.

## Also unmeasured: the responder direction

Shelf joins repeated request headers into one comma-separated value and the responder never
splits them, so a handler reading metadata a peer sent twice sees one joined value. Whichever
rule the owner picks should apply there too, and nothing has measured it.

## Owner decision

Which of the two, and whether the responder direction follows. Both change observable metadata,
so both want a CHANGELOG line.
