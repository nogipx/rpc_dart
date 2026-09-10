---
round: 293
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 293 — lenses for the mandate

## Target

The owner's observation, mid-round: *the lens set is all defect-shaped, so a
refactor round reaches for the worst file it can see instead of auditing
everything* — and then, that these belong in a pack rather than only in this
project's set.

Both are right, and the first explains rounds 289-292: each found something
real, but each picked its target by instinct because nothing in `lenses/`
described this kind of work.

## Hypothesis

A refactor mandate needs its own detectors, and the two this repository has paid
for are general enough to be catalog shapes rather than project lenses.

## Before

```
lenses, all defect-shaped                22
lenses for doc comments or API surface    0
packs enabled                             core, dart, async-io, server
```

And the doc-comment baseline the mandate is measured against:

```
rpc_dart/lib/src   4430 doc lines / 24049 total   18.4%
```

## Mechanism

n/a — this round adds detectors and applies one; it fixes no defect.

## After

Two catalog shapes, in a new `refactor` pack:

- **U-22 — the narrative beside the code.** A doc comment carrying the SEARCH
  that produced the code rather than what to pass. Detector: `///` against
  total, then three questions per comment.
- **U-23 — public by omission.** The surface is whatever nobody underscored.
  Detector counts the surface, measures who uses each candidate outside the
  implementation, and checks whether the implementation imports its own public
  barrel — that last is a prerequisite, and round 290 found it by breaking the
  build.

Instantiated here as **RPC-23** and **RPC-24**, with rounds 289-292's numbers as
their evidence. `packs:` in `config.md` gains `refactor`.

The pack states two things the other packs do not need to: the severity bar is
suspended for a refactor mandate (a doc comment is exactly what "only very
critical" would refuse), and `bench: none` is legitimate, because both numbers
are counts rather than measurements needing a probe.

**RPC-23 applied, first slice.** `RpcSecurityPolicy`:

```
field                        before  after
maxActiveStreams                 33      7
maxConcurrentHandlers            43     11
closeOnProtocolError             17     10
halfOpenStreamTimeout            34     13

file total                      236    151
```

Nothing lost — those tables are rounds 205, 213-215 and 245, which are dated and
which `stale` ages. What a caller needs survives in a quarter of the space.

## Canary

n/a. The analyzer is the witness for the doc edit — `public_member_api_docs` is
enabled, so a comment deleted rather than rewritten goes red — and it is clean.

## Gate

`fvm dart analyze --fatal-infos --fatal-warnings lib` on `rpc_dart`: clean.
`loop.py lint` green, including the catalog and pack checks.

## Not fixed

The rest of the audit. 151 of `security_policy.dart`'s lines are still doc, and
the file-level ranking says where the remaining work is:

```
responder_pipeline.dart   308     base_processor.dart      227
channel_transport.dart    303     context.dart             176
transport.dart            238     rate_limiter.dart        161
```

That is now a detector's output rather than a hunch, which is what the owner
asked for and what this round exists to make possible.

## Links

RPC-23 (new, `applied: [293]`), RPC-24 (new, `applied: [289, 290, 291, 292]` —
the rounds that paid for it, recorded retroactively because the lens is derived
FROM them). Catalog U-22 and U-23; pack `refactor`.
