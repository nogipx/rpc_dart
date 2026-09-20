---
round: 417
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-25
bench: none — both defects are a DISAGREEMENT between two written-down answers,
  read off the source; the confirmation is three ablations, each restoring one
  of the old answers and failing a named witness
commit: yes
---

# Round 417 — one table, one grammar

## Target

**B-66 and B-67, both of which were parked as `owner decision` and both of which
the owner's "backward compatibility does not matter, make it perfect" answers.**
Neither needed measuring — each is two or three written answers to one question,
and the work is choosing.

Taken together because they are the same shape at the same seam: a rule the
transports each answered for themselves.

## Hypothesis

The better-argued copy wins in both cases and the rest is deletion.

**Half right.** It held for the grammar. For the status table it was too
blunt — see below.

## Before

```
                      rpc_dart_http          rpc_dart_http2
HTTP 400              invalidArgument        internal
HTTP 429              resourceExhausted      unavailable
HTTP 500              internal               unknown
HTTP 504              deadlineExceeded       unavailable      <- RETRYABILITY
unmapped              >=500 internal,        unknown
                      >=400 invalidArgument

/Service/Method       responder_pipeline     512, hardcoded
                      security_policy        maxMethodPathLength, default 1024
                      metadata               258 (_maxMethodTokenLength*2+2)
```

## Mechanism

**504 is the row that changes behaviour rather than wording.**
`RpcRetryInterceptor` retries `unavailable` and `resourceExhausted` and nothing
else, so a gateway timeout was retried over HTTP/2 and final over HTTP/1.1 — the
same deployment, the same proxy, the same application code, and swapping the
transport silently swapped the retry policy.

**The method-path knob was monotone DOWNWARD only.** `maxMethodPathLength` is
enforced by every transport through `validateMetadata`, so the sweep's claim
that it does nothing was wrong. What is true is narrower: raise it past 512 and
nothing changes, because `_parseMethodPath` held a fourth copy with 512
hardcoded and refused the path afterwards. Lower it and it bites. A setting that
silently ignores half its range.

And the three did not agree on the GRAMMAR either — exactly-three-parts plus a
token regex, versus non-empty-with-a-leading-slash, versus a third per-token
rule — so **the layer the embedder can configure was the loosest and the
strictest had no configuration at all.**

## After

**One table**, `grpcStatusFromHttpStatus` in `protocol.dart` beside
`wireStatusFor`, called by both transports. **One grammar**,
`parseRpcMethodPath` in `metadata.dart`, with the limit passed in:
`RpcSecurityPolicy.parseMethodPath` supplies the configured one and
`_parseMethodPath` now just asks the transport's policy. Raising the knob past
512 works; lowering it still bites.

### Where the hypothesis broke, and an existing test is why

The http2 table is grpc-go's `HTTPStatusConvTab` exactly, so "adopt it and
delete the other" looked like the whole answer. It is not: **413** and **499**
are kept beyond it.

`oversized_request_is_resource_exhausted_test` failed, and its header names its
direction — a body over `maxMessageLengthBytes` is answered 413 by rpc_dart's
OWN responders, and RESOURCE_EXHAUSTED is what tells the caller it hit a SIZE it
can reduce rather than sent malformed arguments. The http2 sibling answers the
same status for the same condition via `_answerFramingViolation`. My argument
for dropping it — that RESOURCE_EXHAUSTED is retryable and retrying an oversized
body is futile — is the weaker one: the remedy is the caller sending less, and
the status is how it learns that.

499 is kept on the same test: nginx really emits it, and CANCELLED is its exact
inverse in gRPC's own gateway mapping. Everything else the HTTP/1.1 table added
— 409, 410, 412, 415, 501 and the `>=400` default — is gone, because no rpc_dart
responder emits those and the `unknown` rule covers them.

## Canary

Three, each restoring one old answer.

```
old answer restored              witness failed with
512 hardcoded in the grammar     "raising maxMethodPathLength past 512 now has
                                 an effect" AND "GUARD: lowering it still
                                 refuses" -- BOTH, which is the pair: with the
                                 number hardcoded the knob is ignored in both
                                 directions
504 -> deadlineExceeded          "504 is retryable, and it is the same answer
                                 on both transports"
413 -> unknown (my first cut)    "an oversized request is RESOURCE_EXHAUSTED,
                                 not INVALID_ARGUMENT" and "a 413 carries WHICH
                                 limit was hit" -- two EXISTING tests, which is
                                 how the table got corrected
```

The first is the one worth keeping: a canary that fails the witness **and** its
guard says the mechanism was absent rather than wrong, which is a different
defect from the one the witness alone describes.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check   compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**The per-token 128-character rule is gone**, not merged: `_maxMethodTokenLength`
bounded each token and the unified grammar bounds the whole path. A 1000-char
service name with a 20-char method now passes where it did not. No test covered
it and no producer emits one; stated here rather than discovered later.

**B-66's three "related, same seam, not verified" items stay unverified** —
HTTP/1.1's trailer handling possibly dropping `grpc-status-details-bin`, and
`content-type` being required on one side and unchecked on the other. They are
B-70's, and the CORS half of that seam was already closed in round 415.

**B-67's adjacent item is untouched**: `RpcContext._sanitizeHeaders` as a second
home for the policy's defaults. Same "the knob does not reach the code" shape,
filed in B-70 as item 13.

## Links

- B-66, B-67 — both closed here
- RPC-25 — the duty is "what does a non-200 mean" and "what is a valid path"
- B-70 — items 13 and 36 are the same shape as B-67 and remain
