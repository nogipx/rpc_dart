---
round: 556
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-08
bench: none — the witness is git against the published tags, which is what CLAUDE.md's release step 1b prescribes; nothing to run
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
---

# Round 556 — no published core satisfies any floor, and it does not matter yet

## Target

B-154, from the external-audit intake, `round: — (not re-measured)`. It claims the transport
pubspecs declare `rpc_dart` floors below the core APIs they call, naming three symbols, and marks
its own confidence **medium** with nothing measured.

First of the ~50 audit leads to be measured. Chosen because its witness is exact, deterministic and
cheap — `git show <tag>` is the published source — and because B-129 records that this intake's
grading is wrong in BOTH directions.

**No code changed. The fix was applied and then REVERTED on the owner's instruction**, and that is
the round's most useful outcome; see `## The owner re-graded it`.

## Hypothesis

From the lead: `http >=6.0.0` and `websocket >=6.1.0` are too low for `maxFramedMessageBytes`,
`isAcceptableContentType` and `RpcNoConnectionException`; `melos run bump:rpc_dart` closes it at the
next release.

## Before

```
core pubspec             version: 6.3.0
published core tags      6.0.0  6.1.0  6.2.0  6.3.0

rpc_dart_isolate / http / wasm / http2    rpc_dart: '>=6.0.0 <7.0.0'
rpc_dart_websocket                        rpc_dart: '>=6.1.0 <7.0.0'
```

## Mechanism

Core's pubspec reads `6.3.0` and `rpc_dart-6.3.0` is tagged, so the published core and the declared
version are the same number while the tree has gained 82 commits of core changes since. A floor
covering what the transports call would have to name a version that does not exist — which is why
the lead's `melos run bump:rpc_dart` sketch cannot be carried out on its own. Core has to be bumped
first.

## After

Swept the whole surface rather than the three symbols the lead names: every public TYPE added to
core since the lowest declared floor, each grepped across the transports, each checked against every
published tag.

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

**Confirmed, and larger than filed: seven of the eight are in NO published core at all** — not at
the floor each transport declares, and not at 6.3.0, the newest. `IRpcReconnectableTransport` is
referenced by all five transports, and at the `rpc_dart-6.3.0` tag that identifier appears only
inside this journal's own files, nowhere in the code.

So the shape is not "the floors are a little low": **every transport declares a floor that no
published core satisfies.** Published as they stand, each resolves the highest allowed core and
fails to compile.

`IRpcAdvisoryChannelError` is the row that is RIGHT — core 6.1.0, used only by websocket, whose
floor is `>=6.1.0`. Somebody raised that one deliberately.

Beyond the transports, four more packages use a type absent from every published core
(`RpcClosedException`: `rpc_blob`, `rpc_blob_sqlite`, `rpc_notify`, `rpc_notify_redis`). `rpc_data`
is clean — the two exceptions it uses are both in 6.0.0.

## The owner re-graded it, and that is the finding worth keeping

Asked for the version number, the owner chose **6.4.0, a minor** — recorded with its cost stated:
18 of the 82 core commits since 6.3.0 carry `!`, so on `^6.0.0` a user would auto-upgrade into
breaking changes rather than opting in. Their call, made with the number in hand.

Then, told the bump had been applied across all 20 packages, the owner **reverted it** on this
reasoning:

> nobody but me uses the package

**Which collapses the severity, and the lead cannot see that.** A dependency floor binds only a
resolver OUTSIDE this workspace — inside, the pub workspace always takes core from local source,
which is exactly why the gate cannot see this class and why it drifted in the first place. With one
consumer, the failure the lead names has nobody to happen to.

So B-154 was worth about ten minutes, not a round, and the measurement above is now permanent at
near-zero cost. `lib/`, every pubspec and the lockfiles are byte-identical to their committed state.

**And a METHOD error of mine is on the record with it.** `melos run bump:rpc_dart` raises all 20
packages by design, and I ran it rather than editing the 9 I had proven needed it — on the reasoning
that my sweep was type-level only so I could not prove the other 11 safe. That is a gap in the
method, not evidence about those packages, and it widened a change beyond its measurement.

## Canary

**None, and none is possible.** Nothing was switched off: the round counted what a published
artefact contains. What stands in for one is the `IRpcAdvisoryChannelError` row — a symbol that IS in
a published core, whose user declares a floor covering it. Without that row the table would read
identically whether or not the method could tell the two cases apart.

## Gate

Run once with the bump in place, all four green (`analyze`, `test:unit`, `format:check`,
`license:check` at 2140 files) — which is itself the point: **a green gate says nothing about this
class.** The pub workspace resolves core from local source, so analyze and test pass over a floor no
published core satisfies, and `melos run prepare` would too.

After the revert nothing in the repository differs from its committed state, so there is nothing for
a gate to check.

## What is left

**Decided and NOT to be re-derived**: the number is `6.4.0` when it happens, and it happens at
release, not in a round. Step 1b (`melos run bump:rpc_dart`) is the mechanism and the table above is
the list it must cover — including the four non-transport packages, which the lead's `paths:` do not
name.

**Open, and the owner's**: whether the ~49 remaining audit leads should be re-graded for a single
consumer. A large part of that intake is written for an audience that may be empty — *"a third-party
transport that forwards raw chunks"* (B-126, which round 553 spent itself on), *"an external
implementer gets silent corruption"* (B-116), and this lead. If that audience does not exist, those
drop below the severity bar and the backlog is much smaller than it looks. Asked; unanswered.

## Not fixed

**Only added TYPES were swept, not added MEMBERS.** The diff was read for new class, enum, mixin and
extension declarations; a new method or field on an existing type is the same defect and this method
misses it — `maxFramedMessageBytes` and `isAcceptableContentType` are both of that kind and appear
above only because the audit named them. A complete sweep needs the public member diff.

**Whether anything already published is broken was not established.** Each package's own `version:`
may also be ahead of its tag; this round read floors, not pub.dev.

## Links

Lead `../backlog/B-154-transport-pubspec-floors-are-below-the-core-api-they-use.md` —
CONFIRMED, larger than filed, severity re-graded by the owner, deferred to a release and then CLOSED
on their instruction so no round takes it again.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [556]`.
