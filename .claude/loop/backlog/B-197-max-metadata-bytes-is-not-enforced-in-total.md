---
status: closed (round 524)
round: 524
commit: 7cdaabf6
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart]
probe: P-159
reason: "closed — fixed in round 524 with a running total inside the existing header loop, so 8 headers of 8 KiB now refuse at 65620 > 65536 where they previously passed at 8x the limit. The count check still refuses BY COUNT and a larger configured limit still admits more"
---

# B-197 — `maxMetadataBytes` is never enforced in total, so the real ceiling is 16x it

**Split out of B-129 by round 523.** That lead files this among eighteen "hygiene
items" whose witness is *"None — read and delete"*. It is a DoS surface, and filing it
at that severity is how it would have been closed without being looked at.

## Measured (round 523)

Default policy: `maxMetadataBytes = 65536`, `maxHeaderValueBytes = 8192`,
`maxHeaders = 128`. Every header below is individually legal — only the SUM is out of
bounds:

```
   1 headers x 8192 B  =     8227 B total  ( 0.1x the metadata limit)  -> ACCEPTED
   8 headers x 8192 B  =    65620 B total  ( 1.0x the metadata limit)  -> ACCEPTED
  64 headers x 8192 B  =   524818 B total  ( 8.0x the metadata limit)  -> ACCEPTED
 128 headers x 8192 B  =  1049646 B total  (16.0x the metadata limit)  -> refused
                                            (Too many metadata headers: 129 > 128)

CONTROL one header of 8193 B (over the PER-HEADER limit)  -> refused
```

**The 128-header row is refused by the header COUNT, not by size.** So the effective
ceiling is `maxHeaders x maxHeaderValueBytes` — about 1 MiB — and
`maxMetadataBytes` bounds nothing that `maxHeaders` does not already bound worse.

The control matters: one oversized header IS refused, so per-header validation works
and the rows above are about totals rather than about nothing being checked.

## Why it matters

`RpcSecurityPolicy.maxMetadataBytes` is the knob an operator sets to bound metadata.
It is off by 16x in the direction that costs memory.

**The channel transports are covered by accident**: `RpcChannelFrame._decodeAt`
bounds the encoded metadata blob against `maxMetadataLen` (round 506 moved that check
above the completeness test). **The HTTP transports are not** — they validate through
`policy.validateMetadata` and never reach that decoder.

So this is the shape RPC-08 keeps finding: a bound enforced on one transport and
absent on its siblings, with the field's name promising it everywhere.

## Fix sketch

Sum `name.length + value.length` across the headers in `validateMetadata` and refuse
past `maxMetadataBytes`. It only tightens, so the risk is refusing metadata that
passes today — which is the point, but it wants a CHANGELOG line because an
application sending many large headers would start failing.

Worth checking while there: whether the sum should count the encoding's overhead, so
that the policy's number means the same thing at both layers.

## Outcome (round 524) — fixed

```
   8 headers x 8192 B  ->  refused (Metadata too large: 65620 bytes > 65536)
  64 headers x 8192 B  ->  refused (Metadata too large: 65620 bytes > 65536)
 128 headers x 8192 B  ->  refused (Too many metadata headers: 129 > 128)
   1 headers x 8192 B  ->  ACCEPTED
CONTROL one header of 8193 B  ->  refused (Invalid metadata header value)
```

A running total inside the existing loop, checked after each header — so a peer
sending a megabyte of legal headers is refused at 64 KiB rather than after all of it
is resident. Same reasoning as round 506: bound what is ACCEPTED, not what is
retained.

The count check still runs first and keeps its own message, because many tiny headers
is a different fault from too many bytes.

## Still open

**The two layers count different bytes.** `validateMetadata` counts header name and
value text; `RpcChannelFrame` bounds the ENCODED blob, which includes the JSON
framing. So `maxMetadataBytes` means slightly different things at the two layers —
smaller here than there. Reconciling them is a decision about which quantity the field
names, and round 520 found the same confusion in `maxActiveStreams`.

**This tightens a limit**, so an application sending many large headers starts
receiving a metadata violation where it previously succeeded. It wants a CHANGELOG
line aimed at that case.

**The HTTP transports were never driven.** The fix is in the shared policy so they
inherit it, but "a policy that does not bound" was never turned into a measured DoS
through an HTTP transport.

## Owner decision

—
