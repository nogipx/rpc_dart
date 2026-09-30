---
round: 544
verdict: FIXED
packages: [rpc_dart, rpc_dart_http]
lens: RPC-08
bench: P-176 — new
budget: probes 1/5, canaries 3/5
commit: yes
release: none
---

# Round 544 — three wires, one field

## Target

B-209, an owner decision and therefore the round's first target. The decision was **"the field
names the WIRE — the encoded frame — and `validateMetadata` is changed to count the same
quantity"**, with the round owing the derivation of the JSON overhead "before encoding, which is
the part that is not obvious".

Lens RPC-08: one name, one promise, and here the promise is the word `Bytes`.

**The round priced the premise before implementing it, and the premise did not hold.** Put back
to the owner with the numbers; the answer was **keep the text count and document it**, the same
answer B-195 got. So this round is documentation plus the stale prose it found on the way, and
no behaviour change.

## Hypothesis

That "the wire" is one quantity, so a per-header figure derived from name and value lengths can
equal it.

## Before

```
  shape                         text      json      http   json/text  http/text
  1 x 8192 B                     8194      8231      8198       1.00       1.00
  8 x 8192 B                    65552     65645     65584       1.00       1.00
  128 x 64 B                     8594      9647      9106       1.12       1.06
  128 x 8 B                      1426      2479      1938       1.74       1.36

  per-header framing, derived    json 8.2 B/header    http 4.0 B/header

  100 quote chars in one value   text 101   json 227   ACCEPTED by the policy
  100 ordinary chars             text 101   json 127
```

Bench `../probes/P-176-which-wire-does-max-metadata-bytes-mean.md`.

**Two independent refutations.** The per-header framing differs by transport — 8.2 bytes as
JSON against exactly 4.0 as HTTP header lines — so any surcharge added to the shared policy is
right for at most one wire. And the JSON size depends on the value's CONTENT: the same 100
characters cost 127 bytes or 227 depending on whether they need escaping, and a quote is
printable ASCII, which the policy permits. No figure derived from lengths can equal that.

The first two rows are the control: at few large headers all three counts agree within 1%, so
the divergence is a property of the shape rather than of the counting.

## Mechanism

**Severity is much lower than the lead implied, and that is what made documenting it the right
answer.** Reading the enforcement sites rather than the lead:

- `frame_multiplexed_channel.dart:222-232` bounds an inbound metadata frame's DECLARED payload
  length against `maxMetadataBytes` before buffering it, so on channel transports the encoded
  wire is already bounded exactly, on the path a peer controls.
- `rpc_http_responder_transport.dart:320` carries its own aggregate bound over the header lines,
  and its comment already states that counting name + value undercounts by 4 per header and can
  therefore only reject later than the wire would.

So the gap is bounded by `maxHeaders` times a wire's per-header overhead — 512 bytes on HTTP
against a 64 KiB field — and the quantity a peer actually controls is already checked.

**What was wrong was the prose.** `validateMetadata`'s own comment said:

> the HTTP transports validate here and reach no such check

That describes the state before round 524 added the running total, and it is false twice over:
the check is in that function now, and the HTTP responder has had its own aggregate bound as
well. A later reader following it would "fix" a mechanism that already exists.

Fixed: the comment states what the function counts now and that every wire frames it on top;
`maxMetadataBytes`'s doc gains the one thing it did not say — that it counts TEXT, that the
encoded block is always somewhat larger, and that both halves are covered because the count can
only refuse later than a wire would while each transport bounds its own encoded form.

**Two measurements were sitting in `lib/`** and went to the journal where they belong: a
`960 KB accepted with 200 OK` figure in the aggregate-bound comment, and an
`+8.7/+12.6/+40 MiB of RSS` table in the response-buffer comment. The rule each was supporting
stayed; only the numbers moved. The standing requirement is that the search narrative goes in
the commit and the journal, not beside the code.

## After

No behaviour change — the same metadata is accepted and refused as before, which is the point
of the decision. What changed is that the contract is now written where someone configuring the
field will read it, and pinned by a test.

## Canary

**Three, and the first one FAILED — which is the useful part.**

```
A. a per-header surcharge (+8 bytes per header)   FIRST ATTEMPT: PASSED

   The witness at that point used ONE large header, where 8 bytes moves nothing:
   text 101 against a limit of 164. A canary that passes means the test is wrong,
   not the code, so an arm was added for the shape that can see a surcharge --
   64 small headers with the limit just above their text total.

A. the same surcharge, against the new arm

   WITNESS the bound counts text and NOTHING per header
     threw RpcMetadataViolation: Metadata too large: 712 bytes > 698

B. count the encoded expansion (escaping included)

   WITNESS the bound counts TEXT, so a value that EXPANDS when encoded is accepted
     threw RpcMetadataViolation: Metadata too large: 201 bytes > 164
```

Each canary is caught by exactly the arm built for it and by no other: A leaves the
expanding-value arm green, B leaves the many-headers arm green. The two arms are the two ways
the decision could have been carried out, so between them they pin the choice rather than the
code.

The test takes the encoded size from the public `RpcChannelFrame.encodeMetadata` rather than
re-deriving the JSON — the probe's own copy of that encoder is a stand-in, and a test built on
one measures its author.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          2111 / 2111, REUSE compliant
```

`format:check` failed once on the new test and was re-run green. In the changed packages:
`rpc_dart`'s `test/core` and all of `rpc_dart_http` re-run green after formatting.

`test:web` was not run: this round changes comments, one doc comment and a VM-only test, and
nothing on a web path. It is red for B-215 either way.

## Not fixed

**http2's HPACK block is unmeasured**, and it is the third framing. It would only widen the
spread the decision foundered on, so it does not change the answer — but the doc now names
three wires and only two of them have numbers.

**The `-bin` header case is untouched.** Base64 is printable ASCII and does not escape, so it
behaves like the plain arm; a binary value's RATIO of wire bytes to decoded bytes is a different
question from this one and nothing here asks it.

## Links

Lead `../backlog/archive/B-209-two-layers-count-different-bytes-for-one-limit.md` — closed by
this round, with its decision revised by the owner on the measurement.
Bench `../probes/P-176-which-wire-does-max-metadata-bytes-mean.md` — new.
Bench `../probes/P-159-is-metadata-bounded-in-total.md` — the lead's own bench, which measured
the TOTAL and never the framing; unchanged.
Round `524-the-sum-nobody-was-taking.md` — added the running total whose arrival the comment
fixed here never recorded.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [544]`.
