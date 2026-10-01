---
round: 552
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: P-180 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
---

# Round 552 — the window was off, not loose

## Target

The owner's decision on B-195: **document what `flowControlWindowBytes` means** — it is
credit for what is unconsumed, not a ceiling on residency — with the multiplier counted, what
the ratio depends on written down, and **a canary that the field bounds anything at all**.

Carrying that out found the field bounding NOTHING in a configuration the same doc offers, so
the round's subject became the defect and the doc followed the measurement.

Lens RPC-19: one flag, two lifecycle meanings. An inbound end-of-stream meant both "the peer
has finished sending" and "the call is over".

## Hypothesis

From the lead: the window bounds the undelivered portion below the pipeline, so an operator
setting 4 MiB retains ~185 MiB — 45-90x the knob — and the honest fix is to say so.

## Before

```
the window held at 64 KiB, only initialSendWindowBytes moving

  initial off      510806 msgs   sendCredit: 0  advertised: 0  waiters: 0
  initial 4 KiB      4372 msgs   sendCredit: 1  advertised: 1  waiters: 1
  initial 16 KiB     4372 msgs
  initial 64 KiB     4372 msgs
  initial 1024 KiB   4372 msgs
```

`sendCredit: 0` is the finding: **no credit entry existed for the stream at all**, so the
per-stream window was never applied. With `initialSendWindowBytes: null` — documented as
"null to stay unbounded until then", meaning until the first grant — a server stream is
unbounded for its whole life.

## Mechanism

`_onMessage` treated an inbound end-of-stream as the end of the CALL: `_releaseStream`,
`_finishedStreams.remove`, `_forgetStream`. For a stream WE opened that is right — the
inbound end is the response's last frame. For one the PEER opened it is their half-close,
and **a server stream half-closes its request immediately**, so this fired at the start of
every server stream's response phase.

`_forgetStream` drops `_advertised` and `_sendCredit`. `_advertised` is the only record that
a peer-opened stream exists, so `_isStreamLive` then answered false, and `_onGrant` discarded
every later grant as one for a call that had ended. The sender's credit could never be
re-established.

**What hid it is `tryConsume`'s seed.** It writes `initialSendWindowBytes` into `_sendCredit`
whenever the entry is missing — so at the defaults the entry came back, the window worked,
and the whole mechanism was invisible. The seed is gated on that field being non-null, which
is why switching it off switched the per-stream window off with it.

The fix is one condition, using the `locallyInitiated` flag already computed four lines
above. The peer-opened branch still repays the connection pool — the inbound half really is
over — and the send-side state is left to `releaseStreamId`, which the responder pipeline
always calls.

## After

```
  initial off        4372 msgs   sendCredit: 1  advertised: 1  waiters: 1
  ... every row identical at 4372, the configured 64 KiB
```

And what the field charges, which is what the doc owed:

```
  wire 18 B   decoded 1 KiB    4372 msgs   charged 15 B/msg   wire 4 KiB
  wire 1 KiB  decoded 1 KiB      66 msgs   charged 993 B/msg  wire 66 KiB
  wire 1 KiB  decoded 16 KiB     66 msgs   charged 993 B/msg  wire 66 KiB

  window swept: 16 KiB 1095 / 64 KiB 4372 / 256 KiB 17479 / 1024 KiB 69908
```

Bench `../probes/P-180-what-the-window-actually-charges.md`.

**The window is exact: `66 x 993 B = 65 538` against a 65 536-byte window.** It charges WIRE
bytes, admits however many messages those are, and cannot see what one decodes to — 66
messages holding 66 KiB or 1.0 MiB behind one unchanged window.

**So B-195's `185 MiB behind a 4 MiB window` is refuted, and refuted as an artefact of its
own probe.** P-135's `_Blob.toJson` emits `{'n': 1024}`: every "1 KiB message" was 11 bytes
on the wire, and the 185 MiB is `count x a size that never crossed it`. The overshoot was
the codec's expansion factor. Measured on the wire the window never overshot at all.

The doc now states what it counts, that sizing memory from it means multiplying by the
codec's expansion, and that a paused consumer which resumes releases the producer. The
connection-pool field got the same distinction, and both lost a measurement sentence built
on the same arithmetic.

## Canary

**Two, because the round has two halves.**

**A — the field itself off** (`_window => null`), which is the canary the owner asked for:

```
WITNESS the window bounds un-consumed WIRE bytes, to one message
  Expected: <8299>
    Actual: <34726>
  a bound does not move when the producer is given twice as long
WITNESS the bound tracks the configured value   Expected: > 333426  Actual: 51762
WITNESS the window cannot see what a message decodes to
  Expected: be in range 58081..58085   Actual: 54370
CONTROL resuming the consumer releases the producer  Expected: > 104568  Actual: 47130
```

Four of five fail, each with a number. The fifth is the no-window control, which is that arm
already and must keep passing.

**B — the fix off** (the condition forced true):

```
WITNESS a half-closed request does not end the response's window
  Expected: <1>
    Actual: <0>
  the responder advertised its window for this stream and the call is still live
  in the sending direction
```

The mechanism-level arm fails first and on the state, not on a count, which is what makes it
survive a machine whose timings move.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages; rpc_dart 1847 passed, 3 skipped
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   2130 / 2130
```

**The gate caught a real regression and it is worth recording how.**
`flow_control_connection_test.dart`'s "without it the total scales with the stream count"
went red: `30375936` against a `> 31457280` assertion. Reproduced alone and **attributed by
ablation** — with the fix restored to its old form the arm passes — so it was this change and
not the load, which at `load average 6.71` would have been the easy explanation.

That arm is a CONTROL: with no pool, 40 streams at a 1 MB window should pin ~40 MB. Its
threshold sat at 30 MB, 72% of nominal, and the overrun it measures can only ever be a
fraction of nominal because it excludes everything already in flight when the 40 pauses land.
Tightening enforcement moved that fraction by 3% and it crossed the line. **Fixed by giving
the arm headroom — 2 MB per stream, 80 MB nominal — rather than by lowering the assertion**,
which would have weakened a control to accommodate the change under test.

`test:web` was NOT run and that is a gap, not a pass: `load average 6.71 8.46 8.20` is well
above the `uptime` under 3 that B-215 names as the precondition for reading a Chrome result,
so a red there would have been uninterpretable. The change has no dart2js exposure — no
clock, no 2^53, no `async*` cancellation — but the isolate web-worker suites do drive this
transport, so the arm is owed on a quiet machine.

## Not fixed

**Only the server-stream shape is witnessed.** A client stream and a bidi stream half-close
at different moments and the fix is about when a half-close lands; neither is measured here.
Filed as part of B-218.

**The `nominal` column is arithmetic, not memory.** The paused stream's messages stop below
the decode, so nothing was shown to retain them — and round 549's rig note says a zero-filled
`Uint8List` would not be resident even if it were. What a decoded backlog actually costs is
unmeasured, and it is the quantity an operator reading this field cares about.

**`maxBufferedMessagesPerStream` does not bound this path either.** Round 550's ceiling never
fired in any arm: the pipeline drains the transport's per-stream controller, so the ledger
never holds a backlog. B-217 is about the other queue; this is a third observation and goes
to B-218 with it.

**The seed is still the only thing that bounds a sender before the first grant**, which is
what `initialSendWindowBytes` is for. Nothing here changes that, and on a zero-latency pair
it cannot be measured (A2).

## Links

Lead `../backlog/archive/B-195-the-window-is-much-looser-than-its-number.md` — CLOSED: the
decision is carried out and its premise refuted.
Lead `../backlog/B-218-the-other-half-closes-are-unmeasured.md` — new, what this round did not
cover.
Bench `../probes/P-180-what-the-window-actually-charges.md` — new.
Bench `../probes/P-135-does-the-window-reach-a-direct-object.md` — its `_Blob` is where the
185 MiB came from; still valid for its own question, which is about direct objects.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [552]`.
Lens `../lenses/RPC-15-remeasure-own-record.md` — the lead's premise refuted on re-measurement.
Round `550-a-queue-depth-for-an-object.md` — the depth ceiling, which this path does not reach.
Round `206-connection-credit-never-repaid.md` — the repayment the first version of this fix
removed, caught by its test.
