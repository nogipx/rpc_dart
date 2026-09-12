# What paid for each test item

> [Methods](METHODS.md) · the operative list is [tests.md](tests.md), printed by
> `loop.py brief` · the protocol that proves a test is a witness and not a
> guard: [canary.md](canary.md) · language and domain items:
> [items/](../items/ITEMS.md)

Open a section when its item is the one biting.

## Expectations and time

**Check "unbounded" by POLLING up to a threshold, not by counting after a fixed
sleep** — otherwise you are measuring the CPU.

Boundedness allows a fixed sleep only when YOUR process does the thing you
await. A test that slept a flat 4 s while a disconnect travelled client ->
proxy -> server and fired a close callback, then asserted "0 open connections",
passed 4/4 alone and failed falsely under a full suite: load delays the
OBSERVATION, not the production. Poll up to a deadline instead — the witness
stays exactly as sharp, because a genuinely orphaned connection never closes and
consumes the whole budget.

If you are waiting for zero, first wait for the rise. Never compare two
independently measured runs as a ratio; check both against one absolute bound.

## Fixtures

**NEVER put a literal control character (or any invisible byte) in a fixture —
BUILD it.** A test held a real 0x01 byte, invisible in the source. A new case
typed the value as ordinary text `'ctrlchar'` — printable ASCII, entirely VALID
— so the server correctly did not refuse, the test hung to its timeout, and it
read exactly like a transport regression. Three probes went into bisecting a
difference that was in the FIXTURE. Build the character from a code point; an
escape is easy to lose in an edit. The language idiom is in
`items/tests-dart.md`.

**For every "this input is rejected" witness, a paired case "a valid input is
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

- **Say when a flake's mechanism is NOT pinned.** Hardening measured defects is
  worth doing; calling it a flake fix is not. Name the one path worth
  instrumenting next.
- **`| head -N` on a grep can hide the evidence that REFUTES the hypothesis.** A
  grep for inbound metadata validation returned 12 lines under `head -12` with
  the server side not among them — one step short of a false security finding.
  **When grep output is truncated, the absence of a match proves nothing.**
- **"Every place" means every LAYER, and a sweep of one layer reads as
  complete.** A round fixed all five trailer-assembly sites in core; the next
  found two in the transports, and the worst was where a synthetic refusal is
  emitted INBOUND, so the transport validated it as peer traffic and answered by
  CLOSING THE CONNECTION. **Having swept a pattern, grep the other packages for
  the same constructor before calling it closed.**
