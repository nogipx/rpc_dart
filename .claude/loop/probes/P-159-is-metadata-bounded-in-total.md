---
file: packages/core/rpc_dart/.dart_tool/probe/b129_14_total_metadata_bound.dart
round: 523
commit: 7cdaabf6
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-159 — is metadata bounded in total, or only per header?

## Why it exists

A per-header bound and a total bound are different guarantees, and a policy field
named `maxMetadataBytes` reads as the second. Twelve lines settle which it is, with
no transport involved — `validateMetadata` is public.

## The harness

Headers that are each individually LEGAL, varying only how many there are. That is
the whole design: if any single header were oversized the refusal would say nothing
about totals.

Each value is exactly `maxHeaderValueBytes`, so the sum crosses `maxMetadataBytes` at
eight headers and reaches 16x at the header-count ceiling.

## The numbers (round 523)

```
maxMetadataBytes = 65536, maxHeaderValueBytes = 8192, maxHeaders = 128

   1 headers x 8192 B  =     8227 B total  ( 0.1x)  -> ACCEPTED
   8 headers x 8192 B  =    65620 B total  ( 1.0x)  -> ACCEPTED
  64 headers x 8192 B  =   524818 B total  ( 8.0x)  -> ACCEPTED
 128 headers x 8192 B  =  1049646 B total  (16.0x)  -> refused
                                            (Too many metadata headers: 129 > 128)

CONTROL one header of 8193 B (over the PER-HEADER limit)  -> refused
```

## Measures

Whether `validateMetadata` accepts, and the total byte count it accepted. The REASON
for a refusal is printed too, and that is what makes the last row readable: it is
refused by the header count, not by size, so it is not evidence of a size bound.

## Control

**One header past the per-header limit, which IS refused.** Without it, four rows of
ACCEPTED are equally consistent with `validateMetadata` checking nothing at all — and
the finding would be much larger and wrong.

## What it establishes, and what it does not

Establishes: `maxMetadataBytes` is not enforced in total. The effective ceiling is
`maxHeaders x maxHeaderValueBytes`, about 1 MiB, 16x the configured value.

Does NOT establish that a peer can reach it on every transport. The channel transports
bound the encoded blob in `RpcChannelFrame._decodeAt` (round 506), so they are covered
by a different mechanism; the HTTP transports validate through the policy and were not
driven here. That step is what would turn this from a policy defect into a measured
DoS.

Does NOT weigh the encoding overhead — the policy's number and the channel decoder's
bound count slightly different quantities, which a fix should reconcile.
