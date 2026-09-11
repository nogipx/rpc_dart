---
round: 349
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-02
bench: none
commit: yes
---

# Round 349 — the refusal that could not fit

## Target

RPC-02, which the curate one round earlier put back under "Due a
re-measurement" — the only lens it aged in, and on evidence: rounds 340 and 342
changed refusal behaviour on the transport this lens was swept on, and neither
was measured against it.

## Hypothesis

Round 340 made the responder validate OUTBOUND metadata against the policy. The
refusal it sends when it rejects a request IS outbound metadata, so the lens's
own question applies to the change directly: does a refusal satisfy the rule that
refused?

## Before

`_answerRejectedStream` already knew half of this, and says so:

> Trimmed to the policy this trailer is validated against on the way out:
> `grpc-message` is a header value, so a rejection long enough to explain itself
> could fail the same check that produced it.

That covers `maxHeaderValueBytes`. It does not cover `maxHeaders` — the trailer
carries grpc-status AND grpc-message, so a cap below 2 refuses the refusal:

```
server policy              what the caller saw
maxHeaders 32              ok(x)                                          41ms
maxHeaders  4              status 3: Too many metadata headers...          5ms
maxHeaders  1              status 14: Response ended without a gRPC status 1ms
```

**Row three is the defect.** UNAVAILABLE reads as retryable and invites the peer
to repeat a deterministic policy rejection forever; the truth is INVALID_ARGUMENT
and the peer should never retry. Rows one and two are the control: the same code
path answers correctly whenever the refusal has room.

**Round 340 introduced it.** Before that round the responder did not validate
outbound, so the refusal went out regardless.

## Mechanism

One rule was ported into the refusal's construction and the other was not.
`RpcMetadata.forTrailer(status, message:, maxMessageLength: ...)` bounds the
value; nothing bounds the count, and the count is the one the refusal cannot
control — it needs two headers to say both what and why.

## After

The status survives and the text gives way, which is the trade the message
trimming already makes. On `ArgumentError` the responder retries with a
status-only trailer:

```
maxHeaders  1     status 14  ->  status 3
maxHeaders  4     unchanged: status 3 WITH the message
maxHeaders 32     unchanged: ok(x)
```

## Canary

```
the fallback ablated   Expected: <3>
                         Actual: <14>
                       'the peer was told the stream ended without a status —
                        UNAVAILABLE, which reads as retryable — for a
                        deterministic policy rejection'
```

Both GUARDs green in the ablated run, and the first is what stops the fix being
"drop the message always": a refusal that FITS must keep its text, or the
diagnosis is traded away for every rejection rather than the ones that cannot
fit.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `license:check` 1398/1398; `test:unit` 14 packages, 0 failures.

## Not fixed

`maxHeaders: 1` is an extreme setting and the round does not pretend otherwise.
What makes it worth a fix at the cap rather than a lead is that the failure is a
MISDIAGNOSIS on a security path — the peer is told to retry something it must
not — and the repair is four lines inside a branch that already exists.

The same question on the other transports was not asked. `RpcChannelTransport`
builds its refusals through the same `forTrailer` trimming (`base_processor`
carries the identical comment), so the shape is plausible there; measuring it is
a round, not a paragraph here.

## Links

RPC-02 (`applied:` gains 349). The curate is what produced this round: it aged
the lens back in on a `git log` classification, and the lens then found the
defect in the very change that aged it.

> **A round that fixes a rule can leave the rule's own answer outside it.** Round
> 340 applied the policy to outbound metadata and did not ask what happens when
> the metadata is the policy's own refusal. RPC-02 exists for exactly that
> question and was swept clean three rounds before 340 shipped.
