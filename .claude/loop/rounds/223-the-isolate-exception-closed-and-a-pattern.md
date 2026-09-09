---
round: 223
verdict: CLEAN
packages: [rpc_dart_isolate]
lens: RPC-14
bench: none — the detector is a grep plus reading; the ablation is the instrument
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record, and Q4 produced the finding again
commit: no
---

# Round 223 — the isolate exception closed, and a pattern

## Target

Not B-17: declined for the fifth time, unchanged reason. **The reason stopped
holding partway through this round** — the owner cleared the whole
awaiting-decision queue, B-17 included. That intake is recorded below and is in
this round's commit; it did not change the round's target, which was already
measured out.

RPC-14 — "a timeout drops the wait but not the work" — the last entry in the
re-measurement queue. Its status carries an explicit exception, `except
isolate`, and B-04 is that exception written as a lead: the family sweep
happened off-journal and never covered `rpc_dart_isolate`, where the price is a
leaked isolate rather than a socket.

## Hypothesis

One of the isolate package's timeouts abandons its wait while the work — a
spawned isolate, its ports, its subscriptions — carries on, so a failed startup
leaves a live isolate nobody holds.

## Before

```
.timeout( in rpc_dart_isolate/lib                    4 sites

  isolate_transport.dart:419  first handshake     catch -> teardownStartup()
                                                  kills the isolate, cancels
                                                  all three subscriptions,
                                                  closes all three ports
  isolate_transport.dart:571  ready ack           catch -> hostTransport.close()
                                                  then teardownStartup()
  isolate_transport_web.dart:316 initialization   catch -> abandon()
                                                  closes the transport and
                                                  terminates the worker
  isolate_transport_web.dart:385 ready grace      onTimeout: () {} — DELIBERATE
```

## Mechanism

Nothing is wrong, and the fourth site is the interesting one. Its empty
`onTimeout` looks exactly like the defect this lens is about, and is not: the
comment records why — a worker built before the ready protocol never sends the
ack, and hanging those would be a worse regression than the wait. Proceeding
without the ack is the point. `readySub.cancel()` runs on both paths, and a
post-timeout error from the abandoned `Future.any` is dropped by `timeout`'s own
handler rather than reaching the root zone.

So B-04 closes: the isolate exception to RPC-14's sweep is swept, and clean.

## After

n/a — nothing changed. `git diff` empty, `analyze` green.

## Canary

n/a — no fix. The ablation is the instrument, and it says the same thing round
222's did. With `teardownStartup()` removed from the failed-handshake path, so a
crashed or stuck isolate and its ports are left behind:

```
  isolate suite, startup teardown ablated:   +73, All tests passed
```

## Gate

No code changed — the ablation was reverted in place, `git diff` is empty and
`analyze` is green. The ablated run is the measurement above, not a gate result;
the gate proper is the one HEAD passed at round 212.

## Not fixed

**Two rounds, two guards, neither with a witness.** Round 222 removed
`_detached`'s `.catchError` and the core suite stayed green; this round removed
the isolate's startup teardown and its suite stayed green. Both guards exist
because of a measured production failure — two replicas exiting 255, and a
leaked isolate that keeps the host process alive — and both can be deleted
without any test noticing.

That is a pattern rather than two coincidences, and it is worth a rule: this
repository's guards against LEAKS AND CRASHES are systematically untested,
because a test for them has to assert an absence — no process death, no
surviving isolate — which the ordinary suite shape cannot express from inside
the process under test. Filed as `L-04`.

The concrete gap here joins B-20: the isolate package already owns the harness
that could express it, `close_releases_the_isolate_test.dart`, which asserts on
a SUBPROCESS's exit. Extending it to the failed-startup path is small, and is
recorded in B-04's closing note rather than opened as a new lead.

## Owner decisions taken in this round

Asked because the owner asked what was blocking. Seven answers, no code:

```
  B-17  refuse the transport at attach          -> open, ranks first
  B-01  out of the loop, ordinary roadmap work  -> closed
  B-02  accept, record as a negative            -> closed, C-23
  B-19  close the gate over rpc_dart_wasm       -> open, decided
  B-20  approved, write the subprocess witness  -> open, approved
  B-18  approved, plant a dart2js bug class     -> open, approved
  B-10  deferred until core+transport are empty -> deferred
```

**The awaiting-owner queue is now empty for the first time in the journal.** One
verification was done before recommending B-17's answer, because the whole case
for it rests on the claim being true: every first-party caller transport already
implements `IRpcStreamIdSequence` — isolate, wasm and websocket via
`RpcChannelTransport`, http2 and http directly — so refusing at attach breaks no
supported path, only hand-written decorators, which is exactly the population
already losing calls silently.

### The intake produced a second finding, and `lint` is why

C-23 was first written as a record with no number, on the grounds that B-02 had
never been measurable here. `loop.py lint` rejected it — *"a negative without a
control is hope, not a negative"* — and the search done to satisfy it found that
**B-02's central claim is false**:

```
grep for any rejection or error hook, over ios/ and android/     1 hit

  ios/Classes/RpcDartWasmPlugin.swift:162
      window.onunhandledrejection = ...        <- installed deliberately,
                                                  with a comment naming this
                                                  exact class
  android/.../RpcDartWasmPlugin.kt             no hit

  control: the same grep FINDS the iOS handler, so Android's zero is an
           absence in the code, not a failure of the search
```

B-02 said "there is neither an `unhandledrejection` event nor a host callback",
which reads as a project-wide absence. It is a **platform asymmetry**: iOS runs
the guest in a WKWebView with a real `window` and the HTML event loop that
defines the event; Android runs it in androidx.javascriptengine's bare
`JavaScriptIsolate`, which has no DOM, so there is no event to subscribe to. The
"wrap `Promise`" conclusion survives — for Android, and for that reason.

The acceptance stands on the corrected mechanism rather than the wrong one. Rule
one, and the lint enforcing a control is what applied it: a schema check caught a
factual error that reading had not.

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md` — `applied: [223]`, the
`except isolate` exception removed, sweep refreshed to 0e7b984a.
Lead `../backlog/B-04-isolate-future-timeout-unaudited.md` — closed by this
round, with the untested-guard note.
Lesson `../lessons/L-04-a-guard-with-no-witness.md` — new, paid for by two
rounds of ablation.
Round `222-every-site-guarded-the-guard-untested.md` — the first half of the
pattern.
Lead `../backlog/B-20-detached-guard-has-no-witness.md` — the same gap in core;
approved in this round's intake, to be done with B-04's isolate half.
Negative `../checked/C-23-wasm-guest-promise-rejection-accepted.md` — new, from
the intake.
Leads `../backlog/B-17-watermark-lost-through-a-decorator.md`,
`../backlog/B-01-response-metadata-dropped.md`,
`../backlog/B-02-wasm-android-promise-rejection.md`,
`../backlog/B-19-close-the-gate-over-wasm.md`,
`../backlog/B-18-web-guard-is-a-census-not-a-sweep.md`,
`../backlog/B-10-layers-without-lenses.md` — all answered, all re-ranked in
`../backlog/BACKLOG.md`.
