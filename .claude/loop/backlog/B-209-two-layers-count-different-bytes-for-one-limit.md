---
status: decided by owner (round 540)
round: 524 (measured as part of B-197; split out in the round-540 bookkeeping pass)
commit: 6659c0ee
release: breaking
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart]
probe: P-159
reason: "owner decision — `maxMetadataBytes` names a different quantity at each of the two layers that enforce it, and reconciling them is a decision about which quantity the field MEANS. Round 520 found the same confusion in `maxActiveStreams`"
---

# B-209 — `maxMetadataBytes` counts different bytes at the two layers that enforce it

Split out of B-197, which round 524 closed after adding a running total to
`validateMetadata`, so `8 headers x 8192 B` is refused at `65620 > 65536` where it previously
passed at 1.0x. Bench `../probes/P-159-is-metadata-bounded-in-total.md`.

**The two enforcers count different things.** `validateMetadata` totals header NAME and VALUE
text; `RpcChannelFrame._decodeAt` bounds the ENCODED blob, which includes the JSON framing. So
the same configured number admits slightly more at one layer than the other — smaller in the
policy than on the wire.

Round 520 found the same shape in `maxActiveStreams`, which is the argument for treating this
as one question rather than a one-line adjustment: a policy field whose meaning depends on
which layer is asked is a pattern here, not an accident.

**Two things follow from whichever answer is chosen.**

`maxMetadataBytes` TIGHTENED in round 524, so an application sending many large headers now
receives a metadata violation where it previously succeeded. That wants a CHANGELOG line aimed
at exactly that case, and the wording depends on which quantity the field is declared to name.

**And the HTTP transports were never driven.** The fix is in the shared policy, so they should
inherit it — by construction, which is an argument rather than a measurement. RPC-08's
question, unasked.

## Owner decision

**The field names the WIRE** — the encoded frame — and `validateMetadata` is changed to count the
same quantity. Taken in the round-540 review.

The argument: the wire is what an operator can observe and what a peer controls. A limit that is
SMALLER in the policy than on the wire protects something other than what it promises, and the
gap is the JSON framing, which no application chose.

**The same review answered B-128 the same way** — a policy field names what is observable, not
what is convenient for the layer enforcing it. That is now the precedent for this class, and
B-195's decision is consistent with it: there the number stays and the DOC explains what it
counts, because the alternative reached into two earlier rounds.

**It tightens further than round 524 already did**, so it folds into that round's CHANGELOG line
rather than adding a second one — and it makes that line more accurate, since 524's tightening was
to the smaller of the two quantities.

**What the round owes.** Counting the JSON overhead BEFORE encoding, which is the part that is not
obvious: `validateMetadata` sees headers, not a frame, so the figure has to be derived rather than
measured from the blob. P-159 is the bench. The canary is a payload that passes under the old
count and must now be refused, plus one well under both, which is what says the change did not
simply refuse everything.
