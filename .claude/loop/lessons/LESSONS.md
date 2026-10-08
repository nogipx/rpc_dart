# Lessons

What a lesson is and how it is promoted into the skill — [../LOOP.md](../LOOP.md).
The record format — `../../skills/evidence-loop/specs/lesson.md`.

The lessons of rounds 1-205 live in private memory and in the skill's methods,
not here. They cannot be filed after the fact — a lesson must have a cost in
numbers, not a retelling.

- **[L-01](L-01-half-a-fix-can-mask-the-other-half.md)** active — when a fix has two halves, check whether one MASKS the other's witness
- **[L-02](L-02-vary-the-event-not-the-setup.md)** active — when the defect is an EVENT, vary the event, not the setup
- **[L-03](L-03-no-backticks-in-a-shell-argument.md)** active — never put a backtick in a shell argument, not even inside quotes
- **[L-05](L-05-green-locally-is-not-green-clean.md)** active — a gate ablation proves sensitivity, not portability
- **[L-04](L-04-a-guard-with-no-witness.md)** active — a guard with no witness, and how the ablation finds it
- **[L-06](L-06-the-path-the-owner-drives.md)** active — Test the drop the PEER starts, not the one you call
- **[L-07](L-07-instrument-every-hop-at-once.md)** active — Instrument every hop at once; do not reason about which one is wrong
- **[L-10](L-10-a-hand-built-peer-needs-the-real-serializer.md)** active — a hand-built peer must use the library's serializer
- **[L-09](L-09-a-delete-has-an-inbound-half.md)** active — A delete has an inbound half, and an index that does not link is not an index
- **[L-08](L-08-a-per-test-connection-hides-it.md)** active — A per-test connection cannot see a per-connection defect
- **[L-12](L-12-sweep-the-class-not-the-sample.md)** active — sweep the class, not the sample
- **[L-13](L-13-a-decision-inherits-the-sentence-it-was-taken-on.md)** active — a decision inherits the sentence it was taken on
- **[L-14](L-14-a-red-that-reads-like-a-known-flake.md)** active — a red that reads like a known flake
- **[L-19](L-19-a-flake-is-a-hypothesis.md)** active — "it is a flake" is a hypothesis, and it names a variable
- **[L-21](L-21-count-the-socket-where-it-lives.md)** active — count a socket in the process that owns it
- **[L-20](L-20-a-limit-the-sender-cannot-see.md)** active — a receiver limit the sender cannot see fails honest peers
- **[L-18](L-18-the-lead-names-one-side-of-an-adapter.md)** active — A lead that names one side of an adapter needs both
- **[L-17](L-17-a-skip-states-its-conditions.md)** active — a skip states its CONDITIONS, not just its reason
- **[L-16](L-16-copy-what-the-sibling-avoids.md)** active — copy what the sibling AVOIDS, not only what it does
- **[L-15](L-15-a-void-arm-reads-like-a-clean-one.md)** active — a bench arm whose subject never reaches the code reads exactly like a clean one
- **[L-11](L-11-a-gauge-cannot-name-its-own-cause.md)** active — Assert an event at the peer, never by polling a gauge

## Curate after round 348 — all twelve re-read, all still hold

`stale` ages eight of them; the classification is the same as the lenses' and it
comes out the same way. Two were APPLIED in this block and are stronger for it,
not weaker:

- **L-01** (one half masks the other's witness) — round 343 hit it on a
  redundancy that is DELIBERATE rather than accidental: `_streamParsers` is
  pruned at two sites and either alone suffices, so the single-site ablation
  read exactly like a bench with no sensitivity. That case is not in L-01's own
  record and is now the clearest instance of it.
- **L-11** (a gauge cannot name its own cause) — round 339 applied it to the
  last three assertions of its kind in `rpc_dart_http2`, and the CI failure that
  prompted it was the same message L-11 was written about, `Actual: <0>` versus
  `Actual: <1>`.

**No candidate for a thirteenth, and that is a deliberate call.** Rounds 337-348
produced four rules that read like lessons — sweep the class before the sample,
an arm reporting zero must prove it could report one, a comment naming the
mechanism is not the same as having read it, a step that runs last is only as
reliable as everything before it. The first is already **L-12**; the other three
are each written into the round that paid for them and into the lens or bench
that carries them forward. Filing them here as well would grow the layer whose
binding constraint is the attention it costs to read, which is the same argument
this file already makes against promoting lessons into `methods/`.

## Promotion candidacy — curate pass after round 220

All three hold OUTSIDE this repository, so all three are candidates for the
skill. None has been promoted, because editing `methods/` or
`references/` is a separate SKILL commit and this pass touches project data
only. Each was re-read against its own test — "does the rule hold in any code?"

- **L-01** → `methods/canary.md`. It already says a two-half fix needs two
  canaries; what L-01 adds is the failure mode where one half MASKS the other's
  witness, and the remedy (build the witness so the other half cannot cover).
  Nothing in it is specific to flow control.
- **L-02** → `methods/measurement.md`, next to "the control differs by exactly
  one thing". Its addition is the case where the hypothesis is about a
  TRANSITION: both arms must be asserted equal before they diverge.
- **L-03** → `references/rule-zero.md`, which already forbids substitutions. The
  addition is *why it is worse than a broken string*: it also defeats the
  allowlist and therefore prompts the owner, which is the thing rule zero
  exists to prevent.

**L-04 arrived after that pass** and is the strongest promotion candidate of the
four: it is a rule about what Q4's ablation is FOR, so it belongs next to the
ablation requirement in `references/review.md` and in `methods/measurement.md`.
Nothing in it is specific to Dart or to this repository — "a guard against an
absence cannot be witnessed from inside the thing that would disappear" holds in
any language with in-process test runners. It waits on the same separate skill
commit as the other three.

Round 218 produced a fourth candidate rule that is NOT yet filed as a lesson,
because its price is recorded in the round rather than counted: prevention and
detection are not interchangeable when the caller's handle is the only thing
identifying the work. If it recurs, file it.
