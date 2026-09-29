---
round: 521
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-23
bench: P-158 — new
commit: yes
---

# Round 521 — a cleanup list with defects in it

## Target

B-129, "core: dead code, misleading docs and duplicated helpers" — thirty-sixth in
the audit's rank and the last of the core cost class.

Lens RPC-23, pointed at the lead itself rather than at the code. The lead's own
framing — *"Each is small; together they are the reading cost"*, witness *"None —
read and delete"* — is a claim about severity, and it is wrong for several of its
eighteen items.

## Hypothesis

Item 13: the retry backoff's `Future.delayed` ignores the call's cancellation token,
so a cancel during backoff waits up to `maxDelay`.

## Before

`maxAttempts: 5`, backoff fixed at 4 s, handler always UNAVAILABLE:

```
cancel DURING the backoff     status 1 (CANCELLED)     after 2118 ms
CONTROL cancel immediately    status 1 (CANCELLED)     after 1504 ms
CONTROL no cancel at all      status 14 (UNAVAILABLE)  after 5237 ms
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b129_retry_backoff_cancel.dart`

**Item 13 is NOT confirmed as filed.** A cancel at 300 ms returns at 2118 ms against
an uncancelled baseline of 5237 ms, so the call does not sit out `maxDelay` — the
cancellation demonstrably shortens it.

**But two numbers here are unexplained, and this round does not explain them:**

1. **A ~1.5-1.8 s lag between cancelling and completing.** The immediate-cancel
   control returns at 1504 ms for a cancel at t=0. Whatever that is, it is not
   "prompt", and it is not the 4 s backoff either.
2. **The uncancelled baseline is 5237 ms**, where `maxAttempts: 5` with a 4 s backoff
   implies roughly 16 s. Something ends the retry sequence early and this round did
   not find out what.

So the verdict is INCONCLUSIVE rather than CLEAN: the lead's specific claim is
refuted, and the measurement raises two questions it cannot answer.

## Mechanism

Not established.

## After

Nothing. `lib/` is unchanged.

## Canary

n/a — nothing was fixed. **The never-cancelled control is what made the other two rows
readable**; with only the two cancel arms, both returned ~1.7 s and the table said
nothing, because there was nothing for them to be shorter THAN.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**B-129's real problem is that it is not one lead.** It bundles genuine hygiene —
an unused parameter, merged doc comments, a wrong dart2js claim — with at least four
items that are behavioural defects and would each be filed separately if read on their
own:

- **item 14**: `validateMetadata` never enforces `maxMetadataBytes` in TOTAL, so 128
  headers of 8 KiB each pass. Only the channel frame decoder bounds it, which means
  the HTTP transports do not. That is a DoS surface, not a hygiene item.
- **item 15**: `forClientRequest` caps each token at 128 characters while the policy's
  path limit is 1024, so a long dotted service name the server accepts cannot be
  called. A reachable interop failure.
- **item 16**: `break` after the first decoded response silently drops any further
  messages in the chunk, and the "extra response" warning below it is unreachable.
- **item 13**: the one measured here, whose stated claim is refuted but which left two
  unexplained timings.

**Filing them as one "read and delete" lead sets the wrong severity and invites a
sweep.** A round that took B-129 at its word would have deleted dead code and left a
DoS surface in place.

The remaining hygiene items are untouched: the eight copies of the policy getter, the
pinned last payload, payloads interpolated into internal logs despite the redaction
machinery, and the rest.

## Links

Lens RPC-23. Bench P-158 (new). Lead B-129 (open, and wants splitting — the
recommendation is recorded there).
