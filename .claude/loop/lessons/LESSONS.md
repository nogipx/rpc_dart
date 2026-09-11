# Lessons

What a lesson is and how it is promoted into the skill — [../LOOP.md](../LOOP.md).
The record format — `../../skills/improvement-loop/specs/lesson.md`.

The lessons of rounds 1-205 live in private memory and in the skill's methods,
not here. They cannot be filed after the fact — a lesson must have a cost in
numbers, not a retelling.

- **[L-01](L-01-half-a-fix-can-mask-the-other-half.md)** active (round 206), bench — when a fix has two halves, check whether one masks the other's witness
- **[L-02](L-02-vary-the-event-not-the-setup.md)** active (round 207), bench — when the defect is an event, vary the event and not the setup
- **[L-03](L-03-no-backticks-in-a-shell-argument.md)** active (round 210), toolchain — never put a backtick in a shell argument; substitution both mangles the text and defeats the allowlist
- **[L-05](L-05-green-locally-is-not-green-clean.md)** active (round 226, billed on CI), toolchain — a gate ablation proves SENSITIVITY, not PORTABILITY; round 226's four arms were all correct and CI still went red with 304 errors, because the ablation varied the code and held the environment fixed
- **[L-04](L-04-a-guard-with-no-witness.md)** active (rounds 222-223), bench — after a sweep says "every site is guarded", ablate a guard: twice in a row nothing went red, because a guard against a leak or a crash is witnessed by an absence
- **[L-06](L-06-the-path-the-owner-drives.md)** active (round 234), bench — when a lifecycle event can be started from either side, test the one the PEER starts: five tests calling `reconnect()` themselves stayed green for seven rounds while the path that begins with the socket dying was broken
- **[L-07](L-07-instrument-every-hop-at-once.md)** active (pre-201, imported after 234), bench — instrument every hop at once instead of arguing about which is wrong: three of four attempts at flow control were lost to diagnosing by argument, and one counter per hop found it in minutes
- **[L-10](L-10-a-hand-built-peer-needs-the-real-serializer.md)** active (round 277), fixture — a bench that speaks to the server as a raw peer must build its body with the library's own `codec.serialize`, not by hand: rpc_dart's wire format is CBOR and nothing in the request shape says so. Two rebuilds, and the failure is invisible because `wireStatusFor` is DEFAULT DENY — every cause comes back as the literal "Internal server error"
- **[L-09](L-09-a-delete-has-an-inbound-half.md)** active (round 239), process — a delete has an INBOUND half, and an index that does not link is not an index: 19 dangling links, then 10 orphaned notes, both found by the owner
- **[L-08](L-08-a-per-test-connection-hides-it.md)** active (pre-201, imported after 234), fixture — a per-test connection cannot see a per-connection defect: 74 green tests over a caller that killed its own connection after 4 calls. The reproduction is one loop on one connection
- **[L-11](L-11-a-gauge-cannot-name-its-own-cause.md)** active (round 321, billed on CI), metric — assert an event at the peer, never by polling a gauge that rises and falls: three rounds on one assertion, both CI failures reading `Actual: <0>`, which is what a sample says whether nothing happened or it never looked

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
