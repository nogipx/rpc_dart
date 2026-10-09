---
file: packages/transport/rpc_dart_http/.dart_tool/probe/a_message_at_exactly_the_limit.dart
round: 458
commit: 720439a0
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/transport/rpc_dart_http/lib/**]
status: valid
---

# P-109 — a message at exactly the limit, per transport

## Why it exists

B-80 is about five bytes, so the bench has to hit an exact boundary. The variable
is the TRANSPORT, holding the message and the configured limit fixed.

## The construction that makes it exact

**Set the limit to the message's own serialized length.** `maxMessageLengthBytes:
_codec.serialize(message).length` — then "a message at exactly the limit" is true
by construction and the test never has to predict what CBOR does to a
1000-character string. Guessing the serialized size is how this arm would
otherwise become approximate, and an off-by-five defect cannot be measured
approximately.

## The numbers (round 458)

```
                                       before fix   after fix
channel, limit = exactly the message   ACCEPTED     ACCEPTED
http,    limit = exactly the message   REFUSED (8)  ACCEPTED
channel, limit = message + 5           ACCEPTED     ACCEPTED
http,    limit = message + 5           ACCEPTED     ACCEPTED
channel, limit = message - 1  GUARD    REFUSED (14) REFUSED (14)
http,    limit = message - 1  GUARD    REFUSED (8)  REFUSED (8)
```

## Measures

Whether one unary call is accepted, and the status if not. The handler echoes the
LENGTH it received, so an acceptance also proves the whole message arrived rather
than a truncated one.

## Control

Two, and the second is a guard rather than a control.

1. **`limit = message + 5`** — accepted on both transports, before and after. This
   is what makes the refusal attributable to the five bytes rather than to the
   message being large.
2. **`limit = message - 1`** — refused on both, before and after. Widening a bound
   by five bytes is exactly the change that can remove it, so an arm that proves
   the bound still bites is not optional here.

## What it establishes, and what it does not

Establishes: HTTP/1.1 bounded the FRAMED body by a limit expressed in MESSAGE
bytes, so its effective ceiling was `maxMessageLengthBytes - 5` while the channel
transports honoured the configured value exactly.

Does NOT cover http2. Its parsers receive `maxMessageLength` and the parser adds
the prefix itself (`parser.dart:113`), so the units look right — but that is read,
not measured. B-79 is the lead for what http2 bounds.

Note the two transports also disagree on the STATUS for an oversized message —
RESOURCE_EXHAUSTED against UNAVAILABLE, the latter because a channel server closes
the connection on an oversized frame. Pre-existing, visible in the guard rows.

## Reading

rpc_dart_http + core — an off-by-five defect cannot be measured approximately,
so **the limit is set to the message's own serialized length**: "exactly at
the limit" is then true by construction and nothing has to predict what CBOR
does to a 1000-character string. Varies the TRANSPORT, holds message and limit
fixed. Two arms on the far side: `limit + 5` accepted everywhere (so the
refusal is the five bytes) and `limit - 1` refused everywhere (so widening the
bound did not remove it). The handler echoes the LENGTH it received, so an
acceptance also proves nothing was truncated
