---
status: decided by owner (round 556) — 6.4.0 at release, not in a round
round: 556
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/pubspec.yaml, packages/transport/rpc_dart_websocket/pubspec.yaml, packages/transport/rpc_dart_isolate/pubspec.yaml, packages/transport/rpc_dart_http2/pubspec.yaml, packages/transport/rpc_dart_wasm/pubspec.yaml]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-154 — transport pubspecs declare rpc_dart floors below the APIs they call

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Http `>=6.0.0`, websocket `>=6.1.0` while they use `maxFramedMessageBytes`, `isAcceptableContentType`, `RpcNoConnectionException` (added 2026-09-28, after core's version became 6.3.0); invisible to the workspace — release flow step 1b (`bump:rpc_dart`) is where this closes.

## The shape

`git log -S` dates: `maxFramedMessageBytes` 071cd0e (2026-09-28),
`RpcNoConnectionException` d4c9285 (2026-09-28); core `version: 6.3.0` since
7993c50 (2026-09-22). Tags are absent from the auditing clone, so whether 6.3.0
is published was not checked.

## Why it matters

A published transport resolving an older core fails to compile.

## Witness a round would build

`git show <release-tag>:<core file>` grep for the symbols, per CLAUDE.md 1b.

## Fix sketch

Run `melos run bump:rpc_dart` at the next release; bump core's version if 6.3.0
is already out.

## Outcome (round 556) — CONFIRMED, and far larger than filed

`../rounds/556-no-published-core-satisfies-any-floor.md`.

Swept every public TYPE added to core since the lowest declared floor, grepped each across the
transports, and checked each against every published tag:

```
symbol                        6.0.0  6.1.0  6.2.0  6.3.0   used by
IRpcReconnectableTransport      NO     NO     NO     NO     all five transports
RpcClosedException              NO     NO     NO     NO     http, http2, websocket
RpcNoConnectionException        NO     NO     NO     NO     http2, websocket
RpcMetadataViolation            NO     NO     NO     NO     http2
RpcContentTypeValidation        NO     NO     NO     NO     http, http2
maxFramedMessageBytes           NO     NO     NO     NO     http, http2
isAcceptableContentType         NO     NO     NO     NO     http, http2
IRpcAdvisoryChannelError        NO    yes    yes    yes     websocket
```

**Seven of eight are in NO published core at all** — not at each transport's declared floor and not
at 6.3.0, the newest tag. `IRpcReconnectableTransport` is referenced by all five transports and at
the `rpc_dart-6.3.0` tag appears only inside this journal's files, nowhere in the code. So this is
not "the floors are a little low": **every transport declares a floor that no published core
satisfies**, and published as they stand each resolves 6.3.0 and fails to compile.

`IRpcAdvisoryChannelError` is the row that is right — core 6.1.0, used only by websocket, whose
floor is `>=6.1.0`. It is also what stands in for a canary: without it the table would read the
same whether the method could tell the two cases apart or not.

**The fix sketch cannot be carried out as written.** `melos run bump:rpc_dart` has nowhere to point:
core's pubspec still reads `6.3.0` and that version is tagged, so the tree has gained public API
with no version bump. Core must be bumped FIRST.

Beyond the transports, four more packages use a type absent from every published core
(`RpcClosedException`: `rpc_blob`, `rpc_blob_sqlite`, `rpc_notify`, `rpc_notify_redis`). `rpc_data`
is clean — the two exceptions it uses are both in 6.0.0. The lead's `paths:` name none of these.

## Owner decision

**Round 556 — the number is 6.4.0, and it waits for a release.**

Asked with the table in hand, the owner chose **`6.4.0`, a minor**, with the cost stated: 18 of the
82 core commits since 6.3.0 carry `!`, so on `^6.0.0` a user auto-upgrades into breaking changes
rather than opting in. Decided anyway; not to be re-derived.

The bump was then applied across all 20 packages via step 1b and **REVERTED on the owner's
instruction**, on this reasoning:

> nobody but me uses the package

**That collapses the severity and this lead cannot see it.** A floor binds only a resolver OUTSIDE
this workspace — inside, the pub workspace always takes core from local source, which is why the
gate cannot see the class and why it drifted. With one consumer, the failure named here has nobody
to happen to.

So: **not a round's work. Carry it out at release**, where step 1b does it mechanically and the
table above is the list it must cover, the four non-transport packages included. `lib/`, every
pubspec and the lockfiles are byte-identical to their committed state.

**A method error of the round's is recorded with it**: `bump:rpc_dart` raises all 20 packages by
design and was run rather than editing the 9 proven to need it, on the reasoning that a type-level
sweep could not prove the other 11 safe. That is a gap in the method, not evidence about those
packages, and it widened a change past its measurement.

**Still open and the owner's**: whether the ~49 remaining audit leads should be re-graded for a
single consumer. Much of that intake is written for an audience that may be empty — *"a third-party
transport that forwards raw chunks"* (B-126, which round 553 spent itself on), *"an external
implementer gets silent corruption"* (B-116), and this lead. Asked in round 556; unanswered.

Not swept: added MEMBERS rather than types, which this method misses — `maxFramedMessageBytes` and
`isAcceptableContentType` are both of that kind and are here only because the audit named them.
