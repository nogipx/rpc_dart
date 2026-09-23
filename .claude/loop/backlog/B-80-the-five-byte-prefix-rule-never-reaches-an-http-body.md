---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/core/frame_multiplexed_channel.dart, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**]
probe: —
reason: cost — split out of B-70 item 31; the consequence is a message at exactly the limit, which nobody has constructed
---

# B-80 — the "+5 bytes of prefix" rule exists twice, both times in core

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

—
