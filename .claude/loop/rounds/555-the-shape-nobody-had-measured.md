---
round: 555
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-180 — reused
budget: probes 0/5, canaries 1/5
commit: yes
release: none
---

# Round 555 — the shape nobody had measured

## Target

B-218's first item: **round 552 changed stream lifecycle and witnessed one shape.** A server
stream half-closes its request immediately, so it hit the defect on every call and is what the
witness was built on. A BIDI caller half-closes while the responder goes on sending — the same
inbound end-of-stream, a different shape — and nothing measured it.

Lens RPC-15, aimed at a record three rounds old rather than a stale one: the fix is right where it
was measured and unmeasured elsewhere, on a hot lifecycle path.

**No code changed.** The shape is clean, and the deliverable is that this is now known rather than
assumed.

## Hypothesis

From B-218: "bidi runs through that same helper and is therefore fixed by construction and
measured by nothing". If the `locallyInitiated` gating is wrong for a shape whose request side
ends early but whose call does not, the window stops engaging exactly as it did for a server
stream.

## Before

```
round 552, server stream, window held at 64 KiB

  initial off      510806 msgs   sendCredit: 0  advertised: 0
  initial 4 KiB      4372 msgs   sendCredit: 1  advertised: 1
```

The bidi column did not exist.

## Mechanism

Nothing to change. The fix gates on `locallyInitiated`, which is a property of the STREAM and not
of the method shape, so every peer-opened stream keeps its send-side window past the peer's
half-close — bidi included.

What made this worth measuring rather than reasoning: the argument for bidi is identical to the
argument for server-stream, and that argument was wrong once already. Round 552's defect existed
because an inbound end-of-stream was read as the end of the call, which is also "obviously" fine
until a shape half-closes early.

## After

```
bidi, window 64 KiB, two settle times

  initial off     msgs 4372 -> 4372   charged/msg 15 B   sendCredit: 1  advertised: 1  waiters: 1
  initial 64 KiB  msgs 4372 -> 4372   charged/msg 15 B   sendCredit: 1  advertised: 1  waiters: 1
```

Bench `../probes/P-180-what-the-window-actually-charges.md`, which gained a bidi block.

`4372` at both settle times is a bound rather than a rate; `charged/msg 15 B` is the same figure
the server-stream sweep reads, so the window is charging wire bytes here too and is exact —
`4372 x 15 = 65 580` against 65 536. **And it holds with the initial send window OFF**, which is
the configuration that exposed the defect on server-stream.

## Canary

```
round 552's fix ablated (the `locallyInitiated` gate forced true)

  bidi, initial off      msgs 250569 -> 496486   sendCredit: 0  advertised: 0
  bidi, initial 64 KiB   msgs   4372 -> 4372     sendCredit: 1

WITNESS a BIDI responder keeps its window past the half-close
  Expected: <9226>
    Actual: <34482>
  the window must still bound a responder whose peer has finished
```

**So the bidi shape DID have the defect** — unbounded, no credit entry, nothing advertised — and
round 552's one condition is what covers it. That is what makes this a measurement rather than a
restatement: the arm is shown able to see the defect before it is used to report its absence.

The second row is the masking again: with an initial send window set, the seed re-creates the
credit entry and the shape looks bounded whether or not the fix is there.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages (second run — see below)
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   2138 / 2138
```

**The first `test:unit` run FAILED and that is reported rather than re-run into silence.**
`rpc_dart_websocket`'s `peer_ids_return_to_zero_test` threw `Null check operator used on a null
value` on `health().details['peerStreamIds']!` — a key the same call had returned `0` for three
seconds earlier.

It is not this round's: `git status` showed `lib/` byte-identical to its committed state, the only
modified file being a core test. It passes alone (5 of 5) and the next full run had websocket at
`241`. `load average 9.62 12.68 11.07`, far above the bar `config.md` sets for believing an
intermittent failure. **Filed as B-219 rather than dismissed**, because a diagnostic that can omit
a key it documents is a defect in the diagnostic, and the test asserts through a `!` so it reports
a crash instead of the fact.

## Not fixed

**The client-stream shape is still unmeasured, and the reason it is lower risk is now explicit.**
552's change only affects streams the PEER opened; for a client-stream upload the sender is the
CALLER, which minted the id and holds it in `_activeStreams`, so its liveness never depended on
the state that was being dropped. Bidi was the harder case and the one measured. An arm for the
caller side would cost another rig and is on B-218.

**The bidi FRAME column from round 554 is still missing.** `P-155` has no bidi arm, so the
mid-frame half-close answer is fixed by construction there in exactly the way the window fix was
here. Same lead, same cheap shape.

## Links

Lead `../backlog/B-218-the-other-half-closes-are-unmeasured.md` — its first item discharged for
bidi, the rest intact.
Lead `../backlog/B-219-a-health-detail-went-missing-under-load.md` — new, from the gate.
Bench `../probes/P-180-what-the-window-actually-charges.md` — gained a bidi block.
Round `552-the-window-was-off-not-loose.md` — the fix this round measured on a second shape.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [555]`.
