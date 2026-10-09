---
name: network-audit
description: How to audit rpc_dart as a network library — the audit methods professional reviews use (attack-surface mapping, per-unit resource accounting, stateful fuzzing, conformance suites, differential testing against grpc-go, fault injection, lifecycle driving, dependency and defaults review), a catalog of known vulnerability classes with a probe recipe for each (WebSocket, codecs, isolate/worker/wasm message passing, HTTP/1.1, the RPC layer, HTTP/2 in brief), and the design rules an RPC ecosystem is judged by (deadlines, cancellation, retries and budgets, backpressure, overload, error model, wire evolution, identity). Use it whenever the request is an audit, a security or robustness review, "is this vulnerable to X", a CVE or known-attack sweep, a pre-release hardening pass, a review of a new transport or a new public API against best practice, or choosing what the evidence loop should look at next. It says WHAT to check; the evidence-loop skill says how a suspicion becomes a finding.
---

# Auditing rpc_dart

This skill is a catalog and a method. It does not replace the evidence loop.

- **This skill** picks the target: which attack, which unit, which entry point,
  which design rule, and what a pass looks like.
- **The evidence-loop skill** turns a suspicion into a finding: probe, control,
  fix, canary, gate, journal record. Every suspicion this skill produces goes
  through it. A checklist item is a question, never an answer.

The journal in `.claude/loop/` already holds hundreds of rounds, many of them on
exactly the classes below. Read it through `loop.py`, never with grep or cat (a
hook blocks that):

```
python3 .claude/skills/evidence-loop/scripts/loop.py find '<words>'
python3 .claude/skills/evidence-loop/scripts/loop.py find --path <file>
python3 .claude/skills/evidence-loop/scripts/loop.py find --lens RPC-17
```

A record found there is a hypothesis about the code at its sha. It can point at
a target or say "this was measured once"; it cannot rule a target out. If the
paths it names have moved (`loop.py stale`), re-measure.

## Priorities

1. **Core** (`packages/core/rpc_dart`) and the transports the owner uses:
   **WebSocket, isolate, in-memory/channel, wasm, HTTP/1.1.**
2. **HTTP/2 is low priority.** The owner finds it awkward and does not lean on
   it. Its known-attack list is kept short; audit it only when asked or when a
   finding in a shared layer reaches it anyway.
3. Other packages (`data`, `notify`, `blob`, framework companions) are out of
   scope for rounds. A suspicion there becomes a lead, not a round.

## Modes

The first word of the arguments picks the mode. With no arguments, ask which
mode.

- **`surface <package>`**: map the attack surface of one package. Follow
  [references/methods.md](references/methods.md) §1–2. Output: the
  entry-point table, below.
- **`known [<area>]`**: sweep known vulnerability classes. Areas: `websocket`,
  `codec`, `message-passing`, `http1`, `rpc`, `http2`, `generic`. With no area,
  do them all in priority order. Catalog:
  [references/known-vulnerabilities.md](references/known-vulnerabilities.md).
- **`method <name>`**: apply one audit method to one target, e.g. `method fuzz
  websocket` or `method lifecycle RpcClientConnection`. Methods:
  [references/methods.md](references/methods.md).
- **`design <thing>`**: review a public API, a new transport or a proposed
  change against the RPC design rules in
  [references/rpc-design.md](references/rpc-design.md).
- **`full <package>`**: surface, then known, then design, in that order.

Where things live in this repository (entry points, the limits that already
exist, the fuzzers and interop tests already in the gate):
[references/rpc-dart-surface.md](references/rpc-dart-surface.md). Read it
before the first probe. It names symbols, so confirm each one with dart-runner
(`find_symbol`, `outline`) before relying on it.

## The procedure for one check

Do these steps for every catalog item or design rule you take up.

1. **Ask the journal.** `loop.py find` with the class's search words and its
   lens id. Note what was measured, at which sha, and whether the paths have
   moved since.
2. **Locate the code.** Use the dart-runner tools. Find the entry point that
   receives the attacker's bytes, the place the bytes become resident, and the
   place the limit is checked. A limit checked after residency is the most
   common defect in this class of software.
3. **Write the probe as a recipe first.** What the hostile peer sends, through
   which real transport, what is measured (peak RSS, live timers, open
   subscriptions, handler invocations, status code, whether a fresh call still
   succeeds), and the **control**: the same run with the hostile property
   removed. A probe with no control measures nothing.
4. **Decide the pass condition before running.** Example: refused with
   RESOURCE_EXHAUSTED; peak resident bytes no more than a small multiple of the
   limit; server still answers a new call within its deadline.
5. **Hand it to the evidence loop.** A confirmed suspicion becomes a round
   (`/evidence-loop round`) or a lead (`loop.py new`). A clean result is still
   recorded: it becomes a negative, so the next audit does not repeat it.
6. **Never report a class as covered because a limit with the right name
   exists.** Report what you measured.

## Entry-point table (output of `surface`)

| Entry point | Peer trust | First byte read by | Resident before any limit | Limits that apply | Pre-auth? | Journal records |
| --- | --- | --- | --- | --- | --- | --- |

Fill one row per place that accepts input from outside the process, or from
another isolate, worker or wasm guest. "Resident before any limit" is the
column that finds bugs. Write what holds the bytes (a dependency's buffer, a
`BytesBuilder`, a `StreamController`) and how large it can grow.

## Reporting

Rank by this order. Each rung outranks everything below it:

1. Reachable by an unauthenticated remote peer, before any limit.
2. Amplification: the peer sends little and the process holds or computes a lot.
   State the ratio you measured.
3. The process dies, or every call on the connection dies (as opposed to one
   call failing).
4. It persists after the peer leaves (leaked timers, subscriptions, ids).
5. Wrong status, wrong retryability, a misleading log.

The loop's severity bar and round cap live in `.claude/loop/config.md`. Read
them through `loop.py status`; this skill does not restate them.

Lead the report with what changed, then what was measured. Do not restate
the catalog back to the user.
