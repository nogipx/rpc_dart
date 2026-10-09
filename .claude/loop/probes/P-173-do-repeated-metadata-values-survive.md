---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b144_repeated_headers.dart
round: 540
commit: 7fe7351c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-173 — do repeated metadata values survive a request, and what does the response split?

## Why it exists

Both halves of B-144 are about a value count, and a count is the one thing Dart's list
printing cannot show: `['Mon', '29 Sep …']` and `['Mon, 29 Sep …']` have the same
`toString()`. **The first reading of this probe reported the response headers as intact for
exactly that reason.** Every value is now quoted and the length printed.

## The harness

A bare `HttpServer` that records the request headers it received and answers with a
gRPC-shaped response carrying two standard fields whose values legally CONTAIN a comma:
`date` (after the weekday) and `www-authenticate` (inside a quoted string). Neither field's
definition permits list recombination.

The request is driven through the transport directly, and the metadata is built with
`methodPath:` passed explicitly — rebuilding `RpcMetadata` from `.headers` alone drops it,
the frame becomes a control frame, and no request fires at all. The probe's first run showed
`null` everywhere for that reason; round 488 had already recorded the trap.

## The numbers (round 540)

```
  half one — two values of `x-tag` on the request
    the server received: [second]

  half two — every header the caller ended up holding
    date                   2 value(s): "Mon" + "29 Sep 2026 12:00:00 GMT"
    www-authenticate       2 value(s): "Basic realm="one" + "two""
    content-type           1 value(s): "application/grpc+proto"
    grpc-status            1 value(s): "0"
```

After the send-side fix, half one reads `[first,second]`.

## Measures

The values the server received for one repeated key, and the number of values the caller holds
per response header — quoted and counted, never printed as a bare list.

## Control

The single-value headers in the same table (`content-type`, `grpc-status`) are the control for
half two: they arrive as one value, so a split that fired on everything unconditionally is
distinguishable from one that fired on the comma.

## What it establishes, and what it does not

Establishes: two values of one metadata key became one on the request (last wins), and the
response side splits standard fields whose comma is inside a single value.

Does NOT say which response-side rule is right. Splitting is correct for Custom-Metadata — the
code argues that at length and the argument holds — and wrong for `date`; distinguishing them
needs either a standard-field list or a decision to stop splitting. Filed, not chosen.

Does NOT cover the responder direction, where shelf joins repeats and the transport never
splits them.

## Reading

rpc_dart_http — **quotes and COUNTS every value, because the question is how
many there are and Dart's list printing cannot answer it**: `['Mon', '29 Sep
…']` and `['Mon, 29 Sep …']` have the same `toString()`, and the first reading
of this probe called a split intact for that reason. Its response arm uses two
standard fields whose comma sits INSIDE one value (`date`,
`www-authenticate`), with single-value headers in the same table as the
control. Passes `methodPath:` explicitly — rebuilding `RpcMetadata` from
`.headers` drops it and no request fires.
