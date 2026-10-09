---
round: 524
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-159 — reused
commit: yes
release: breaking
severity: S2
---

# Round 524 — the sum nobody was taking

## Target

B-197, split out of B-129 by round 523 and measured there. This round is the fix
round 523 declined to ship ungated.

Lens RPC-08: one name, one promise, one transport.

## Hypothesis

Already CONFIRMED in round 523. `validateMetadata` bounds each header and never the
sum, so the effective ceiling is `maxHeaders * maxHeaderValueBytes` rather than
`maxMetadataBytes`.

## Before

```
   1 headers x 8192 B  =     8227 B total  ( 0.1x the metadata limit)  -> ACCEPTED
   8 headers x 8192 B  =    65620 B total  ( 1.0x the metadata limit)  -> ACCEPTED
  64 headers x 8192 B  =   524818 B total  ( 8.0x the metadata limit)  -> ACCEPTED
 128 headers x 8192 B  =  1049646 B total  (16.0x)  -> refused BY COUNT, not size
CONTROL one header of 8193 B  -> refused (per-header)
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b129_14_total_metadata_bound.dart`

## Mechanism

The loop over headers validated each name and value and never accumulated. Nothing
else in `validateMetadata` looked at size, so `maxMetadataBytes` never fired — every
refusal came from `maxHeaders` or from the per-header check.

## After

```
   1 headers x 8192 B  ->  ACCEPTED
   8 headers x 8192 B  ->  refused (Metadata too large: 65620 bytes > 65536)
  64 headers x 8192 B  ->  refused (Metadata too large: 65620 bytes > 65536)
 128 headers x 8192 B  ->  refused (Too many metadata headers: 129 > 128)
CONTROL one header of 8193 B  ->  refused (Invalid metadata header value)
```

A running total inside the existing loop, checked after each header, so a peer sending
a megabyte of legal headers is refused at 64 KiB rather than after all of it is
resident.

**Accumulated INSIDE the loop rather than summed first**, which matters for the same
reason round 506 moved a limit above a completeness check: refusing after totalling
the whole list would bound what is retained rather than what is accepted.

**The count check still runs first and keeps its own message.** A peer sending many
tiny headers is a different fault from one sending too many bytes, and the last row
above shows the distinction survives.

Regression: `test/core/metadata_is_bounded_in_total_test.dart`, 1 WITNESS and 4 GUARD.

## Canary

The total check disabled in place. The WITNESS fails — `Expected: throws ArgumentError
with message containing 'Metadata too large', Actual: <Closure: () => void>` — and all
four GUARDs hold.

The guards are what stop this being a fix that simply refuses more: metadata within
the limit still passes, an oversized single header is still refused for its OWN
reason, too many headers is still refused BY COUNT, and a policy configured with a
larger `maxMetadataBytes` admits correspondingly more — so the bound follows the field
rather than a constant.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**This TIGHTENS a limit, and that is a behaviour change an application can notice.**
One sending many large headers starts receiving a metadata violation where it
previously succeeded. It wants a CHANGELOG line aimed at that case; the fix is correct
either way, because the alternative is a policy field that means nothing.

**The two layers still count different bytes.** `validateMetadata` counts header name
and value text; `RpcChannelFrame` bounds the ENCODED blob, which includes the JSON
framing. So `maxMetadataBytes` means slightly different things at the two layers —
smaller here than there. Reconciling them needs a decision about which quantity the
field names, and round 520 found the same confusion in `maxActiveStreams`. Left
undone, and recorded on the lead.

**The HTTP transports were not driven.** The defect is in the shared policy and the
fix is there too, so they inherit it; but turning "a policy that does not bound" into
"a measured DoS through an HTTP transport" was never done, in round 523 or here.

## Links

Lens RPC-08. Bench P-159 (re-run from round 523). Lead B-197 (closed). Round 521
argued B-129 should be split; 523 split and measured this one; this round shipped it.
