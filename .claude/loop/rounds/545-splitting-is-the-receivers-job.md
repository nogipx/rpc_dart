---
round: 545
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-08
bench: P-173 — reused
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
severity: S2
---

# Round 545 — splitting is the receiver's job

## Target

B-200, an owner decision and therefore the round's first target: **stop splitting** response
headers, rather than maintaining a list of standard fields to exempt. Split out of B-144 by
round 540, which fixed the request half.

Lens RPC-08: one rule, two directions. Round 540 made the SEND side join on `,`; this makes the
receive side stop taking it apart, so the two agree rather than one compensating for the other.

## Hypothesis

The caller splits every response header on `,`, and nothing on the wire says which key's comma
separates values from which key's comma belongs inside one.

## Before

```
  half one — two values of `x-tag` on the request
    the server received: [first,second]

  half two — every header the caller ended up holding
    date                   2 value(s): "Mon" + "29 Sep 2026 12:00:00 GMT"
    www-authenticate       2 value(s): "Basic realm="one" + "two""
    content-type           1 value(s): "application/grpc+proto"
    grpc-status            1 value(s): "0"
```

Bench `../probes/P-173-do-repeated-metadata-values-survive.md`, reused with one arm added.

## Mechanism

The split is replaced by handing the value over as `package:http` combined it — one
`RpcHeader` per field line. `_headerValueDelimiter` becomes unused and goes with it.

**Both comments had to change, and the send side's was the interesting one.** It justified
joining by pointing at the receive side: *"it is what the response side already splits on"*. That
sentence was true and is now false, and a rule whose justification is a mirror of the other
direction breaks silently when one side moves. It now states the rule itself — joined and
repeated are equivalent on the wire, and only the receiver knows its own key's definition.

**The responder direction follows the same rule**, which the decision required: shelf joins a
repeated request header and the responder leaves it joined. That was already the behaviour; what
was missing was any statement that it is intended rather than an oversight, so the code now says
so and names the caller's receive path as the matching half.

**A new arm on the bench, because the decision asked for exactly this.** A repeated CUSTOM key —
the one field whose definition DOES permit recombination — is what separates "stopped splitting"
from "special-cased the standard fields". Canary B below is why that matters.

## After

```
  half one — two values of `x-tag` on the request
    the server received: [first,second]

  half two — every header the caller ended up holding
    date                   1 value(s): "Mon, 29 Sep 2026 12:00:00 GMT"
    www-authenticate       1 value(s): "Basic realm="one, two""
    x-repeated             1 value(s): "one, two"
    content-type           1 value(s): "application/grpc+proto"
    grpc-status            1 value(s): "0"
```

The request half is unchanged, which is what says round 540's join still holds.

## Canary

```
A. the split restored

   WITNESS a repeated CUSTOM key arrives as ONE joined value
     Expected: ['alpha,beta']
       Actual: ['alpha', 'beta']

   WITNESS a standard field whose value CONTAINS a comma is intact
     Expected: ['Mon, 29 Sep 2026 12:00:00 GMT']
       Actual: ['Mon', '29 Sep 2026 12:00:00 GMT']

   Both guards stayed green.

B. the standard-field EXEMPTION LIST — the option the owner rejected
   (split everything except `date` and `www-authenticate`)

   ONE test failed: the repeated CUSTOM key.
   The standard-field witness PASSED.
```

**Canary B is the one the decision asked for in as many words** — "asserting only `date` would
pass a fix that special-cased standard fields after all". It does. So the custom-key arm is what
pins the CHOICE, and the standard-field arm only pins the symptom.

## Three tests were pinning the removed behaviour

`repeated_metadata_splits_on_a_bare_comma_test.dart` asserted that `alpha,beta` splits into two
values — the exact behaviour being removed, from round 540's own fix to the delimiter. Per the
canary checklist: a test that stands only on what is being removed was pinning the defect.

The harness was the valuable part (`_FixedHeadersClient` injects arbitrary response headers with
no socket), so it stayed and the assertions inverted; the file is renamed
`a_joined_response_header_is_not_split_test.dart` after its new subject. A fourth test was added
for the trailer routing, which sits in the same block the fix rewrote and was never at risk from
the split — only from the edit.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          2113 / 2113, REUSE compliant
```

`test:web` not run: `rpc_dart_http`'s web smoke test is in it and this changes a VM-visible
header path, but the target is red for B-215 either way and this round touches nothing
web-specific.

## Not fixed

**No `-bin` arm.** Base64's alphabet contains no comma, so a `-bin` value was never at risk from
the split and is not at risk from stopping it. Stated rather than measured.

**http2 is untouched and does not need this.** It carries metadata as HPACK fields, which arrive
already separate, so there is nothing to join or split — which is worth saying because RPC-08's
question is always whether the siblings agree, and here they agree by having different problems.

## Links

Lead `../backlog/B-200-the-response-split-cuts-standard-headers.md` — closed by this
round; its owner decision is what the fix carries out.
Bench `../probes/P-173-do-repeated-metadata-values-survive.md` — reused; one arm added for a
repeated custom key.
Round `540-the-value-that-never-left.md` — fixed the request half and filed this one.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [545]`.
