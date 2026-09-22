---
round: 429
verdict: FIXED
packages: [rpc_dart, rpc_dart_http]
lens: RPC-15
bench: P-97 — new
commit: yes
---

# Round 429 — two of three were already done

## Target

**B-09**, third of the four the owner listed: three gRPC-compat items, each with
a decision attached. Taken as a whole rather than one item per round, because
the items are independent and two of them turned out to need no work at all.

RPC-15 rather than RPC-22 — the lens is re-measuring the loop's own record, and
that is what this round mostly did.

## Hypothesis

The decisions are 14 rounds old and the items themselves were read out of
private memory, never measured. **The lead's own text warns about exactly this**
for item 3: *"Some later round removed the obstacle and nothing re-read the
deferral... when deferring for blast radius, verify the specific thing you claim
would break, or the deferral is a guess wearing a reason's clothes."*

That warning applies to the lead itself.

## Before

```
item                                    decided            found today
1  split, widen the delimiter           two edits          BOTH LIVE
   a  HTTP/1.1 `value.split(', ')`      widen to ','       live
   b  `-bin` never split (a spec MUST)  split before       live
                                        decoding
2  the 504 row disagrees                align to           ALREADY DONE
                                        `unavailable`
3  truncation, shape (d)                measure first      ALREADY DONE
```

**Item 2** is `grpcStatusFromHttpStatus` in `protocol.dart` — one table for
every transport, `429 || 502 || 503 || 504 => unavailable`, with a doc comment
making B-09's own retryability argument: *"a gateway timeout used to be retried
over HTTP/2 and final over HTTP/1.1 — same deployment, same proxy, same
application code."* The HTTP/1.1 transport calls it and says so at the call
site. Nothing to do.

**Item 3** is P-97, new:

```
d  delivered-then-cut    items=2  error=RpcStatusException  endedClean=false
c  cut-before-delivery   items=0  error=RpcStatusException  endedClean=false
CONTROL complete         items=2  NO ERROR                  endedClean=true
```

The expected reading was `items=2, NO ERROR` — a truncated response the caller
cannot tell from a complete one. It does not reproduce. The control is what
makes that a measurement: a probe whose three arms all said "error" would be
equally consistent with one that cannot report anything else.

**Item 1** is live, and its `-bin` half was measured before being touched, as
the lead demanded:

```
grpc-status-details-bin = "<base64>,<base64>"   statusDetailsBin -> null
```

A comma is in neither base64 alphabet, so `base64.normalize` throws and the
catch returns null. The status and message still arrive, so nothing looks wrong
— the error simply loses its structure.

## Mechanism

Both halves of item 1 are the same mistake about one character. gRPC names `,`
as the delimiter for joined duplicate headers; RFC 9110 only RECOMMENDS
comma-SP. rpc_dart split on `', '` in one place and not at all in the other, so
a peer that follows gRPC's own text is not handled by either.

## After

```
metadata.dart       statusDetailsBin splits on ',', trims, decodes the FIRST
                    non-empty value. Duplicates are separate values, not one
                    value split across lines, so concatenating their bytes
                    would forge a message nobody sent.
http caller         `split(', ')` -> `split(RegExp(r'\s*,\s*'))`, named
                    `_headerValueDelimiter` with the two specs beside it.
```

The HTTP/1.1 comment is rewritten, which item 1's decision asked for
separately: it called the split a KNOWN LIMITATION where "both choices lose
something", and the spec does not agree that loss exists. Splitting IS the
recombination Custom-Metadata's own definition provides for; a value that must
carry a comma belongs in a `-bin` key, whose alphabet has none.

## Canary

```
narrowed back in place              witnesses that failed
_headerValueDelimiter = ', '        "Expected: ['alpha', 'beta']
                                      Actual: ['alpha,beta']"
statusDetailsBin does not split     "unsplit, base64 cannot decode a value
  (the loop body over `[raw]`)       containing a comma, so the details are
                                     dropped and the error arrives with its
                                     structure gone"
                                    and the bare-comma delimiter witness
```

Each ablation fails only its own transport's witnesses. Round 285's unpadded
suite stayed green under both, which is what says the `-bin` change did not
disturb the neighbouring clause on the same line of code.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run test:web       SUCCESS -- 12 dart2js suites, 0 failures
melos run format:check   SUCCESS
melos run license:check  compliant, 1603/1603
```

## Not fixed

**Item 3 needs no fix and gets none, which is not the same as "clean".** What
P-97 establishes is that shape (d) reports an error on the CHANNEL transports.
Whether http2 and HTTP/1.1 do the same on a truncated response is a different
measurement on different code, and this round did not take it.

**`-bin` splitting is fixed for `statusDetailsBin` only.** That is the one
`-bin` header this library reads. Any future one inherits the same MUST and
will not inherit the fix — the split lives in the getter, not in a shared
`-bin` decoder. Stated rather than left for the next round to discover.

**The first value wins when duplicates arrive**, which is a choice: gRPC says
the values are semantically equivalent, so for a single-valued header the first
is the one this call's status refers to. A peer that sends two genuinely
different details blobs is already outside the spec.

## Links

- B-09 — closed. One item fixed, two found already done
- RPC-15 — re-measure your own record. The lead warned about stale deferrals in
  its own item 3 and was stale in two of three
- P-97 — the bench, with the control that makes its negative readable
- round 417 — "one table, one grammar", which did item 2 without the lead
  learning of it
