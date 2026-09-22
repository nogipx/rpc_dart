# Lessons

What a lesson is and how it is promoted into the skill — [../LOOP.md](../LOOP.md).
The record format — `../../skills/evidence-loop/specs/lesson.md`.

The lessons of rounds 1-205 live in private memory and in the skill's methods,
not here. They cannot be filed after the fact — a lesson must have a cost in
numbers, not a retelling.

- **[L-01](L-01-half-a-fix-can-mask-the-other-half.md)** active (round 206), bench — when a fix has two halves, check whether one masks the other's witness
- **[L-02](L-02-vary-the-event-not-the-setup.md)** active (round 207), bench — when the defect is an event, vary the event and not the setup
- **[L-03](L-03-no-backticks-in-a-shell-argument.md)** active (round 210), toolchain — never put a backtick in a shell argument; substitution both mangles the text and defeats the allowlist
- **[L-05](L-05-green-locally-is-not-green-clean.md)** active (round 226, billed on CI), toolchain — a gate ablation proves SENSITIVITY, not PORTABILITY; round 226's four arms were all correct and CI still went red with 304 errors, because the ablation varied the code and held the environment fixed
- **[L-04](L-04-a-guard-with-no-witness.md)** active (rounds 222-223, **isolate half closed in 323**), bench — after a sweep says "every site is guarded", ablate a guard: twice in a row nothing went red, because a guard against a leak or a crash is witnessed by an absence. Round 323 wrote the subprocess witness it asked for and re-measured the claim — `+73 all passed` became `+73 -1`, the only red being the new test — and added that which failure is REACHABLE is decided by code you did not write
- **[L-06](L-06-the-path-the-owner-drives.md)** active (round 234), bench — when a lifecycle event can be started from either side, test the one the PEER starts: five tests calling `reconnect()` themselves stayed green for seven rounds while the path that begins with the socket dying was broken
- **[L-07](L-07-instrument-every-hop-at-once.md)** active (pre-201, imported after 234), bench — instrument every hop at once instead of arguing about which is wrong: three of four attempts at flow control were lost to diagnosing by argument, and one counter per hop found it in minutes
- **[L-10](L-10-a-hand-built-peer-needs-the-real-serializer.md)** active (round 277), fixture — a bench that speaks to the server as a raw peer must build its body with the library's own `codec.serialize`, not by hand: rpc_dart's wire format is CBOR and nothing in the request shape says so. Two rebuilds, and the failure is invisible because `wireStatusFor` is DEFAULT DENY — every cause comes back as the literal "Internal server error"
- **[L-09](L-09-a-delete-has-an-inbound-half.md)** active (round 239), process — a delete has an INBOUND half, and an index that does not link is not an index: 19 dangling links, then 10 orphaned notes, both found by the owner
- **[L-08](L-08-a-per-test-connection-hides-it.md)** active (pre-201, imported after 234), fixture — a per-test connection cannot see a per-connection defect: 74 green tests over a caller that killed its own connection after 4 calls. The reproduction is one loop on one connection
- **[L-12](L-12-sweep-the-class-not-the-sample.md)** active (rounds 333-334, named by the owner), process — count the class before fixing any of it and put the count in `## Target`: 333 measured 58 interpolating log sites in core and guarded 16, 334 guarded 24 more and filed "~20 remain", while the real surface was ~200 across core and four transports. Both records were true and both were subsets; "remaining work" written at the END is a decision the owner never got to make. **Second half, round 425**: a count is taken on an AXIS, and the axis can be wrong — 415 tabulated nine sites with one "cancel unawaited" column, 424 fixed the three rows it marked, and two more instances of the same rule survived in the two files 424 had open, because a bridge has TWO cancel paths and the column held one. Count the PATHS into a mechanism, not the sites that have it; re-derive a sweep's table before extracting from it
- **[L-13](L-13-a-decision-inherits-the-sentence-it-was-taken-on.md)** active (round 380), process — an owner decision is evidence about what the owner WANTS, never about the code: it inherits whatever the round that framed the question got right or wrong, and launders a claim into an instruction on the way. B-47 was decided on round 366's sentence *"the park buys nothing that can be named"*, and 380 measured before carrying it out — **156.25 MiB unbounded against 4.06 MiB with the shipped window, and the decided fix produced 19.95**. Re-measure the SENTENCE, not the decision; the round that executes is the last point where a wrong premise is still cheap. Two ordinary things made it findable: the field's own doc comment contradicted the claim with numbers (a comment is not evidence, and that is not permission to ignore a contradiction), and the arm that would have been the fix was its own control
- **[L-14](L-14-a-red-that-reads-like-a-known-flake.md)** active (round 379, filed in 382), toolchain — **the tell is that it survives the remedy the flake would respond to.** `test:web` failed with a browser-connect timeout three lines below a comment explaining that cold Chromes miss the connect deadline, so it was filed as environmental and left for eleven rounds — through two deliberate re-runs at 3x and 6x. The file did not exist: `dart test` answers a missing path by starting a browser that has nothing to connect to. A cold start responds to waiting longer; this did not. Second tell, one command: a neighbour that should fail the same way and does not. The trap is that the codebase DOCUMENTS the flake, which turns a matching symptom into confirmation
- **[L-17](L-17-a-skip-states-its-conditions.md)** active (round 398), process — **a `skip:` line states its CONDITIONS, not just its reason**, and reproducing the test's PASS under other conditions measures nothing while reading exactly like evidence. B-53's skip said "mid-response"; the lead one directory over spelled it out — *"clean run alone, and not enough under load: the witness still failed inside the workspace gate"*. Round 398 unskipped it and ran it **alone**, twice, on two http2 versions, then under the gate on both — five green runs, and the stated conclusion *"the upgrade is not what changed it"*, which was wrong. **The owner needed one sentence to break it: *maybe the test is wrong?*** The defect was real and the upgrade did fix it: P-73 reads **10 of 10 DEAD on 2.3.1 against 10 of 10 clean on 3.1.0**. Cheaper second half — **the lead's frontmatter NAMES its probe** (`probe: .../abort_kills_the_connection.dart`), a deterministic eight-arm matrix, and that field exists so a later round does not reach for the test that happens to be nearby. A test is shaped by the suite it lives in; a probe is shaped by the question. Sibling of L-15: there the void arm was a silent absence, here the precondition was written down and not re-read
- **[L-16](L-16-copy-what-the-sibling-avoids.md)** active (round 391), process — **copy what the sibling AVOIDS, not only what it does.** When a lens says the sibling holds the answer, half the answer is an absence, and an absence is invisible in a diff. Round 386 fixed a `StateError` by copying `BidirectionalStreamResponder.close()`'s ORDER — cancel, then close — and not the rule the other THREE implementations state in comments: *"Not awaited: a handler stuck in cancel must not block teardown"*, *"cancelling a stalled producer can block indefinitely"*, *"Awaiting it deadlocked cancel()"*. It picked the one copy of five that awaited, and the one that had never been driven with a user-supplied generator. Price: a shipped defect that traded a throw for a permanent HANG on the canonical bidi shape, caught by the owner within hours — and all three of the round's witnesses were green, because its two sources (an `async*` parked on a yield, a plain `StreamController`) both cancel promptly. Read every copy, not the nearest one: five disagreeing 4-to-1 is the majority telling you something. And a fix about a USER-SUPPLIED stream needs a witness with that stream in its worst state
- **[L-15](L-15-a-void-arm-reads-like-a-clean-one.md)** active (round 384), bench — **a bench arm whose subject never reaches the code reads exactly like a clean one.** C-41's `deadline: 0` stood for **twelve rounds** (372-384) and was void: before round 373 a bidi caller holding its request stream open sent no initial metadata, so that arm measured the teardown of a call the server had never heard of. The ablation could not protect it — it removed the responder's cleanup, which the six LIVE arms exercise, so it proved the instrument could see a leak while saying nothing about whether the seventh arm's call ever opened. Re-running the unchanged probe reads 5 / 20 / 27. Cheapest remedy is P-64's HOP CHECK, already invented one round later: sample the server's counters WHILE the call is in flight, so the arm asserts its own setup. Second remedy is a staleness rule `loop.py stale` cannot compute — **when a round changes WHETHER a call reaches the peer, every arm depending on that is stale whatever its paths say**; round 373 touched a file inside P-63's own `paths:` and P-63 was still not re-run. Distinct from `measurement.md` item 8: that asks whether the INSTRUMENT can speak, this asks whether there was anything to speak about
- **[L-11](L-11-a-gauge-cannot-name-its-own-cause.md)** active (round 321, billed on CI), metric — assert an event at the peer, never by polling a gauge that rises and falls: three rounds on one assertion, both CI failures reading `Actual: <0>`, which is what a sample says whether nothing happened or it never looked

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
