---
round: 523
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-08
bench: P-159 — new
commit: yes
severity: S2
---

# Round 523 — the knob that is off by sixteen

## Target

B-129's item 14, taken out of the hygiene list round 521 argued should be split.

Lens RPC-08: a bound enforced on one transport and absent on its siblings, with the
field's name promising it everywhere.

## Hypothesis

`validateMetadata` bounds each header but never the total, so many legal headers add
up past `maxMetadataBytes` and pass.

## Before

Default policy: `maxMetadataBytes = 65536`, `maxHeaderValueBytes = 8192`,
`maxHeaders = 128`. Every header is individually legal; only the sum is not:

```
   1 headers x 8192 B  =     8227 B total  ( 0.1x the metadata limit)  -> ACCEPTED
   8 headers x 8192 B  =    65620 B total  ( 1.0x the metadata limit)  -> ACCEPTED
  64 headers x 8192 B  =   524818 B total  ( 8.0x the metadata limit)  -> ACCEPTED
 128 headers x 8192 B  =  1049646 B total  (16.0x the metadata limit)  -> refused
                                            (Too many metadata headers: 129 > 128)

CONTROL one header of 8193 B (over the PER-HEADER limit)  -> refused
```

Bench:
`packages/core/rpc_dart/.dart_tool/probe/b129_14_total_metadata_bound.dart`

**CONFIRMED, and the last row is the sharp part: it is refused by the header COUNT,
not by size.** So the effective ceiling is `maxHeaders x maxHeaderValueBytes` — about
1 MiB — and `maxMetadataBytes` bounds nothing that `maxHeaders` does not already bound
worse. The knob is off by 16x in the direction that costs memory.

The control is what makes the ACCEPTED rows mean something: one oversized header IS
refused, so per-header validation works and the finding is about totals rather than
about nothing being checked.

## Mechanism

`validateMetadata` loops the headers checking each name and value, and never
accumulates.

**The channel transports are covered by accident.** `RpcChannelFrame._decodeAt`
bounds the encoded metadata blob against `maxMetadataLen`, and round 506 moved that
check above the completeness test. **The HTTP transports are not** — they validate
through `policy.validateMetadata` and never reach that decoder.

## After

Nothing. `lib/` is unchanged.

## Canary

n/a — nothing was fixed.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**The fix is small and I did not have the budget to gate it.** Summing
`name.length + value.length` and refusing past `maxMetadataBytes` is a few lines, but
it only TIGHTENS: an application sending many large headers starts failing, so it
needs the full suite plus a CHANGELOG line, and shipping it unverified would be worse
than leaving it measured.

**Filed as B-197 instead, with the number.** That is the round's substantive output:
round 521 argued B-129 should be split and this is the first split, moving a DoS
surface out of a list whose stated witness is *"None — read and delete"*.

**One question the fix should answer while it is there:** whether the sum should count
the encoding's overhead, so the policy's number means the same thing at the channel
layer and at the HTTP layer. Today the two bound different quantities under one name,
which is the same confusion round 520 found in `maxActiveStreams`.

## Links

Lens RPC-08. Bench P-159 (new). New lead B-197. Round 521 is where the split was
argued; round 506 is why the channel transports are covered.
