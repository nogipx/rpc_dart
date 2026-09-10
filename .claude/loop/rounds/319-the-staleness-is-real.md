---
round: 319
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none
commit: yes
---

# Round 319 — the staleness is real

## Target

After three rounds that changed no code, I claimed the productive findings in
core and transport were exhausted. `loop.py stale` says otherwise, and I had not
run it: **71 of 88 records have aged**, including all four swept lenses.

The target is that number — is it a queue of real work, or noise from my own doc
sweeps?

## Hypothesis

Mostly noise. A record ages when ANY file along its path glob changes, and
rounds 293-306 touched nearly every file in core and transport while recording
"zero code lines changed" each time. If most of the churn is comments, 71 is an
artefact and the loop is as converged as I said.

## Before

```
records aged                71 of 88
  swept lenses               4 of 4   (RPC-02, RPC-09, RPC-14, RPC-19)
  negatives                 27 of 34
  benches                   28 of 31
```

RPC-02 is the worst, 51 files since `0a6e25d5`. Classifying the commits along
its paths:

```
git log --oneline 0a6e25d5..HEAD -- <RPC-02 paths>

total commits                31
  docs(...)  — my sweeps      12
  fix / feat / refactor!      19
```

## Mechanism

**The hypothesis is wrong.** Nineteen of thirty-one are behavioural, and several
land directly on RPC-02's own subject — the refusal path:

```
e481520a  fix(rpc_dart): charge the pre-method budget for metadata too
dcf9d587  fix(rpc_dart_websocket): bound the drain on a refused upgrade
a9cb0846  fix(rpc_dart): charge a queued header for what it retains, not its text
5547e2eb  refactor(rpc_dart_http2)!: stop publishing the HTTP/2 wire machinery
90fba7c8  refactor(rpc_dart): extract the per-stream router
8841b0ee  refactor(rpc_dart): extract the drain loop
```

A sweep is a statement about ONE tree. RPC-02's said "no refusal path violates
the policy" as of `0a6e25d5`; nineteen behavioural commits later, including four
of my own from rounds 308-315, that statement is unverified rather than false —
which is exactly what `swept here` means and why the script tracks the sha.

So the queue is not empty. It is four re-sweeps and a set of negatives that were
established on trees that have since moved, and I called the area converged
without looking.

## After

No code changed. What changed is the plan: the next rounds have a named,
ordered target list instead of "the findings are exhausted".

**Re-sweep order, by behavioural churn along each lens's own paths:**

```
RPC-02   51 files   refusal trailer vs policy      <- most churn, subject touched
RPC-09   34 files   deadline below the write
RPC-14   33 files   timeout abandons work
RPC-19   21 files   one flag, two lifecycle meanings
```

## Canary

n/a — nothing changed. The control for the claim is the classification itself:
had the 31 commits been all `docs(...)`, the hypothesis would have held and the
staleness would have been noise. The command distinguishes the two cases and
returned the answer that contradicted me.

## Gate

Not re-run: no code changed. Last full gate at round 315's `29acab93` — analyze
clean over 21 packages plus wasm, `test:unit` 14 packages 0 failures, format
clean, licence 1317/1317.

## Not fixed

The four re-sweeps themselves. Each is a round: a sweep means reading every site
the lens names on the current tree, and RPC-02's paths alone are 51 files.

**`curate` is also overdue.** The skill says once every ten rounds; the last one
was around 234, and 88 records with 71 aged is what that neglect looks like.

## Links

RPC-15 (`applied:` gains 319) — re-measuring the loop's own records is precisely
its subject, and the record re-measured here is the claim I made in the previous
round's report.

**Fifth instance of the same failure in twelve rounds**, and this one is worth
naming precisely because it did not touch code: I declared an area converged
from the feel of three quiet rounds, with `loop.py stale` unrun. 309, 312, 313
and 316 were each a conclusion reached by reading where a command was cheap;
this was a conclusion reached by *impression* where a command was cheaper still.
The script exists to answer exactly this question and I answered it myself.
