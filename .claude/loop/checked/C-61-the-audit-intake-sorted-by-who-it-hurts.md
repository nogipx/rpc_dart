---
round: 559
commit: 1250b45e
paths: [.claude/loop/backlog/**]
scope: the 47 unworked leads from the external audit of 2026-09-28, graded by whose traffic they can damage
---

# C-61 — the audit intake, sorted by who it hurts

## Why this exists

The intake is a flat list of ~47 leads, each `round: — (not re-measured)`, and rounds were being
chosen from it **by title**. Three rounds' worth of evidence says the list is not uniform:

- **B-154** — every transport's pubspec floor unsatisfiable by any published core. Real, and worth
  nothing: a floor binds only a resolver outside this workspace, and the owner is the only consumer.
- **B-178** — "a potential process kill on reconnect". Severity refuted outright; what was left was a
  comment attached to the wrong call.
- **B-184** — silent request truncation on the owner's own http2 traffic. Real, severe, fixed.

So the intake is **unsorted, not empty** — which is B-129's warning in one sentence. This grades
every remaining lead by one question, and nothing else:

> **Can this damage traffic through a transport as it is used here, with no third party needing to
> exist?**

That question is answerable from each lead's own `## Why it matters` line, which is why this cost one
pass instead of 47 rounds. **It is a ROUTING aid, not a measurement**: a grade is a reading of a
reading, and every lead still owes a witness before anything is believed about it.

## A — can damage the owner's own traffic

Crash, hang, data loss, outage, or a bound that silently does not bind. These are where rounds go.

| lead | what its own line says |
| --- | --- |
| B-151 | crash, total outage (everything 503) after a double start |
| B-192 | double callbacks to user code; a peer that connects and resets immediately |
| B-155 | a CLI or test process that fails to spawn never exits |
| B-158 | a malformed peer takes the whole isolate instead of one call |
| B-161 | one bad message or one stray async error ends every call on the worker |
| B-176 | calls in flight at reconnect hang instead of failing fast |
| B-182 | an application that hangs at startup against a black-holed host |
| B-185 | non-idempotent work retried after it ran |
| B-186 | consumer sees error, then data |
| B-190 | retryable status for work that ran; wrong health |
| B-174 | silent data corruption for buffer-reusing senders |
| B-173 | the defect fixed in isolate and wasm, still live in the public in-memory channel |
| B-166 | one transient failure disables wasm until the app restarts |
| B-163 | host→worker flow control silently off |
| B-165 | flow control silently off, or a lost boot frame |
| B-162 | runs user code at the wrong moment |
| B-175 | the HTTP/1.1 phantom-POST class, on narrower windows |
| B-179 | retry semantics depend on how the death was detected; a race |
| B-189 | a late cancel frame reaches the wrong place |
| B-143 | a shared client breaks for every other user |
| B-153 | a security allow-list that can be undone after construction |
| B-198 | this library's own caller refuses a name its own responder routes |
| B-196 | a gate that fails intermittently is worse than one that fails |

**B-198 and B-196 are in A for a reason worth stating.** Both read like third-party or
infrastructure concerns and are not: B-198's two ends are both rpc_dart, so no outside implementer is
needed, and B-196 costs every future round its evidence.

## B — needs a third party to exist

Real defects whose audience is a proxy, a foreign gRPC implementation, a non-rpc_dart server, or an
external `IRpcChannel` implementer. **Not false**, and not worth a round while the owner is the only
consumer — the grading that closed B-154.

| lead | whose |
| --- | --- |
| B-146 | non-dart:io shelf adapters and proxies |
| B-177 | proxies (GOAWAY invisible through one) |
| B-180 | servers that do not RST — i.e. non-rpc_dart ones |
| B-181 | grpc-go / grpc-java servers attaching rich error details |
| B-183 | proxy credentials, IPv6, virtual-host addressing |
| B-188 | proxies that answer with HTML |
| B-193 | connection-specific headers through an intermediary |
| B-171 | embedders reading the wasm API surface |
| B-191 | information disclosure to an attacker on the refusal path |

**B-191 is the one to re-grade first if the packages ever get a second consumer**, because its
audience is not a collaborator but an attacker, and a public server has those whether or not it has
users.

## C — cost, prose or hygiene, with no behaviour to damage

| lead | what |
| --- | --- |
| B-147, B-149, B-156, B-157, B-159, B-169, B-172, B-152 | stale comments, dead parameters, console noise, false claims |
| B-148, B-160, B-168, B-187 | measured cost only — 8x memory per request byte, per-byte web work, a 50 ms sleep |
| B-164, B-194 | mostly hygiene, each with one behavioural item buried in it |
| B-170 | errors vanishing from level-filtered logs — diagnostics, not traffic |
| B-145, B-150 | one-directional policy, and a documented setup that is the unsafe one |

**C is where rule one bites rather than severity.** A stale comment is a defect the loop fixes in
whatever round touches that file — round 557 is the precedent, where the prose was the only thing
wrong — so these are not a queue, they are a checklist for rounds that pass nearby.

**B-145 and B-150 sit at the C/A boundary on one unknown**: whether the standalone HTTP/1.1 responder
is used here at all. If it is, both move to A, and that is one question to the owner rather than two
rounds.

**B-164 and B-194 must not be taken at their own word.** Both describe themselves as hygiene with
"one behavioural item", and B-129 is the recorded case of exactly that framing hiding a DoS surface.
Split them before working them.

## Control

**The scheme was fitted against three leads whose outcomes were already known and which disagree
with each other**, which is the only thing that can falsify a grading rule without measuring 47
leads:

```
B-154  real, and worth nothing   -> must land in B
B-178  severity refuted          -> must land in C (its surviving half is prose)
B-184  real and severe, own data -> must land in A
```

A rule that put any two of those in one bucket is refuted on the spot, and **the flat list did
exactly that** — it held all three as equals, which is the finding.

The grading question also has to be answerable from the leads' own words, or the pass is 47 rounds
rather than one. It was: every grade above comes from a `## Why it matters` line, and the three
calibration leads were graded from theirs before their outcomes were consulted.

## What this does NOT establish

Every grade is read off a lead's own prose, and those leads were graded wrong in both directions
three times already. **A grade is not evidence**: it says where to look next, and the first thing any
round still owes its lead is a witness.

Nothing here was measured. No lead's status changed, and no lead was closed by being graded.
