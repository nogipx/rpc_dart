---
status: closed (round 458)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/core/frame_multiplexed_channel.dart, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**]
probe: —
reason: cost — split out of B-70 item 31; the consequence is a message at exactly the limit, which nobody has constructed
---

# B-80 — the "+5 bytes of prefix" rule exists twice, both times in core

## CLOSED (round 458). Both halves of the premise above were wrong.

**The rule has THREE homes, not two** — `parser.dart:113` was never counted. And
**`rpc_dart_http` references `maxMessageLengthBytes` in SEVEN places, two of them
enforcing it**, so "does not reference it at all outside one doc line" is false.

The defect is real and sharper than the lead's version: both HTTP sites bound the
RAW body, which is the FRAMED message, against a limit expressed in MESSAGE bytes.
With the limit pinned to one message's exact serialized length:

```
channel, limit = exactly the message   ACCEPTED
http,    limit = exactly the message   REFUSED status=8
both,    limit = message + 5           ACCEPTED    <- so it is the five bytes
both,    limit = message - 1           REFUSED     <- the bound still bites
```

Fixed with one accessor, `RpcSecurityPolicy.maxFramedMessageBytes`, used by both
HTTP sites and by the frame channel, which had it inline. **Bound on the framed
size, REPORT the configured one** — an existing test caught that: naming `max + 5`
names a number the operator never set.

Left alone deliberately: `parser.dart:113`, which is the same arithmetic answering
a different question (a buffer bound, not a single frame). http2 untouched and
unmeasured — B-79 is that lead.

A gRPC frame carries a five-byte prefix, so a limit expressed in message bytes
has to allow for it. Core states that twice:

```
  security_policy.dart:297          effectiveMaxBufferedBytes
  frame_multiplexed_channel.dart:157  under a comment saying that without it
                                      the effective limit "becomes
                                      maxMessageLengthBytes - 5, rejecting a
                                      message at exactly the limit"
```

**Neither `rpc_dart_http` nor `rpc_dart_http2` references
`maxMessageLengthBytes` at all** outside one doc line. So no HTTP body gets the
rule, and the failure the comment describes — a message at exactly the limit
refused — is what those transports would do, if they applied the limit at all.

The second clause is the catch and is why this is a lead rather than a fix: it
is not established that the HTTP transports bound the body by this policy
anywhere. If they do not, the missing +5 is moot and the real finding is the
absent bound, which is B-79's neighbour.

So the round's first question is which limit, if any, an HTTP body is checked
against — then whether the prefix is inside or outside it.

Bench: a message of exactly `maxMessageLengthBytes`, and one of that plus one,
over each of the four transports. Four rows, and two of them are expected to be
"no limit applied", which is itself the answer.

## Owner decision

**Measure first, then apply uniformly** — the same call as B-75 and B-79, given
once for the class.

The lead's own first question stands as the round: which limit, if any, an HTTP
body is checked against. Two of the four expected rows are "no limit applied",
and that is the finding — the missing +5 is moot until a bound exists.

If a bound is added, the "+5 bytes of prefix" rule goes into ONE shared accessor
in core, used by all four transports. Do not write the rule a third time: it is
already stated twice inside core, which is half of why B-85 exists.

New refusals for oversized messages go in the CHANGELOG. DECLINED: applying the
limit without measuring what the HTTP path does today, and documenting it as
unsupported.
