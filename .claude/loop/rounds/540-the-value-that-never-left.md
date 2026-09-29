---
round: 540
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-08
bench: P-173 — new
commit: yes
---

# Round 540 — the value that never left

## Target

B-144: repeated headers are last-wins on requests, and every response header is split on commas.

Lens RPC-08 — two places implementing one rule and disagreeing. The response side splits on `,`
and argues carefully that this is what the metadata field's definition provides for; the request
side then wrote with `map[name] = value` and dropped a value instead of producing that encoding.
One direction implemented the rule the other assumed.

## Hypothesis

`request.headers[name] = value` keeps the last duplicate; the response side splits every header,
so `date` becomes two entries.

## Before

```
  half one — two values of `x-tag` on the request
    the server received: [second]

  half two — every header the caller ended up holding
    date                   2 value(s): "Mon" + "29 Sep 2026 12:00:00 GMT"
    www-authenticate       2 value(s): "Basic realm="one" + "two""
    content-type           1 value(s): "application/grpc+proto"
    grpc-status            1 value(s): "0"
```

Bench `../probes/P-173-do-repeated-metadata-values-survive.md`.

**Both halves CONFIRMED.** The single-value rows are the control for the second: a split firing
on everything unconditionally is distinguishable from one firing on the comma.

## Mechanism

`package:http`'s `request.headers` is `Map<String, String>`, so a second assignment for one key
overwrites the first silently. The value is gone before the request leaves the process.

## After

Half one reads `[first,second]`. Values are grouped by name and joined with `,` — the delimiter
PROTOCOL-HTTP2 names for this, and the one the response side already splits on, so the two
directions now agree.

## Canary

`values.last` in place of the join: the witness fails `Expected: ['first', 'second'] / Actual:
['second']` with its own reason. The single-value control passes, which is what rules out a fix
that always appends a delimiter.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. rpc_dart_http: 174 passed.

## Not fixed

**The response half is filed as B-200, awaiting the owner.** The split is RIGHT for
Custom-Metadata — the code's own argument holds — and wrong for `date`. Telling them apart needs
either a standard-field list (a maintenance burden whose every gap is this defect again) or a
decision to stop splitting (spec-conformant, and it changes what every caller observes). Neither
is a round's to pick.

**The responder direction is unmeasured.** Shelf joins repeated request headers and the responder
never splits them, so a handler sees one joined value where a peer sent two. Named in B-200.

**Three rig errors, all recorded.**

The probe's first run printed `null` for everything: `RpcMetadata` rebuilt from `.headers` drops
`methodPath`, which is a FIELD, so the frame became a control frame and no request fired. Round
488 had already recorded that trap.

Its second run read the response headers as INTACT, because `['Mon', '29 Sep …']` and
`['Mon, 29 Sep …']` have the same `toString()`. Values are now quoted and counted. A list print
cannot answer a question about how many values there are.

And round 539's own control test — a process-wide TCP descriptor count — passed alone and failed
in the full suite: `dart test` runs suites as isolates in ONE process, so every other file's
sockets land in the number. Fixed here to count only sockets to its own port.

## Links

Lens RPC-08. Bench P-173 (new). Lead B-144 closed on the request half; new lead B-200 for the
response half. Round 539's test is repaired in this commit.
