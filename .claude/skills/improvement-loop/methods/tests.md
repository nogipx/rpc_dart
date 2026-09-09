# How to write a regression test that will not lie

## Checklist — while the test is being written

1. Check "unbounded" by polling up to a threshold, not by counting after a fixed
   sleep. A sleep is safe only when YOUR process does the thing you await.
2. If you are waiting for zero, first wait for the rise.
3. Never compare two independently measured runs as a ratio; check both against
   one absolute bound.
4. Build a control or invisible byte in a fixture in code, not as a literal (the
   idiom is in the language pack).
5. For every "this input is rejected", a paired "a valid input is not rejected".
6. Test state is an object the handler captures, not a global counter.
7. If you did not reproduce the reported failure, say so and name the path worth
   instrumenting; hardening measured defects is not a flake fix.
8. A truncated grep does not prove absence; "every place" means every layer.

`loop.py next` adds the enabled packs' items to this list. Below is what paid
for each item.

## Expectations and time

- **Check "unbounded" by POLLING up to a threshold, not by counting after a
  fixed sleep** — otherwise you are measuring the CPU.
- Boundedness did allow a fixed sleep (contention only lowers production, so it
  cannot pass falsely). **CORRECTION: that concession does not hold when you are
  waiting for the PEER to NOTICE something.** A test slept a flat 4 s while the
  disconnect signal travels client -> proxy -> server and fires a close
  callback, then asserted "0 open connections". Load delays the OBSERVATION, not
  the production, so the test failed falsely under a full suite run while
  passing 4/4 on its own. Poll up to a deadline: the witness stays exactly as
  sharp, because a genuinely orphaned connection never closes and consumes the
  whole budget.

  > **A fixed sleep is safe only when YOUR process does the thing you await.**

- If you are waiting for zero, first wait for the rise.
- Never compare two independently measured runs as a ratio; check both against
  one absolute bound.

## Fixtures

- **NEVER put a literal control character (or any invisible byte) in a fixture —
  BUILD it.** A test held a real 0x01 byte, invisible in the source. A new case
  typed the value as ordinary text `'ctrlchar'` — printable ASCII, entirely
  VALID — the server correctly did not refuse, the test hung to its timeout, and
  it read exactly like a transport regression. Three probes and most of a round
  went into bisecting a difference that was in the FIXTURE, not in the library.
  Hence: build the character from a code point rather than a literal or an
  escape — an escape is easy to lose in an edit; the language idiom is in the
  pack (`packs/dart/tests.md`).
- **For every "this input is rejected" witness, a paired case "a valid input is
  NOT rejected".** Otherwise a typo in the fixture makes the witness pass while
  proving nothing.

## State between tests

**Test state must be an OBJECT the handler captures, not a global counter reset
in `setUp`.** A handler leaked from an earlier test keeps running and increments
the shared counter — the canary showed this as "received 4290 of 4000". With an
object, the stale handler writes into its own dead instance.

> **The SHAPE of the failure gives it away:** a counter that can only rise and
> never returns is a stale writer, not a slow close.

## Honesty in the report

- **Say when a flake's mechanism is NOT pinned.** A round hardened two proven
  defects and could not reproduce the reported failure in roughly 10 attempts
  (5/5 alone, two full package runs, a full suite run, and a race-offset sweep
  across the whole window — clean everywhere). That is stated in the commit,
  which also names the one path worth instrumenting next. Hardening measured
  defects is worth doing; calling it a flake fix is not.
- **`| head -N` on a grep can hide the evidence that REFUTES the hypothesis.** A
  grep for inbound metadata validation returned 12 lines under `head -12` with
  the server side not among them — one step short of a false security finding.
  Grepping the file directly showed the validation call, and a behavioural probe
  confirmed it: 200 headers against a ceiling of 4 rejected, the handler never
  ran. **When grep output is truncated, the absence of a match proves nothing.**
- **"Every place" means every LAYER, and a sweep of one layer reads as
  complete.** A round fixed all five trailer-assembly sites in core; the next
  one found two in the transports, and the worst was where a synthetic refusal
  is emitted INBOUND: the transport validates it as peer traffic and answers the
  violation by CLOSING THE CONNECTION. **Having swept a pattern, grep the other
  packages for the same constructor before calling it closed.**
