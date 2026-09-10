---
round: 296
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 296 — a comment on the wrong declaration

## Target

`channel_transport.dart`, 303 doc lines — next by ranking, and the first round
run at the file-sized unit the owner demanded during 295.

## Hypothesis

At a file's scale the audit stops being "cut the long blocks" and becomes a
sweep: every doc block over ~9 lines, in one pass. A sweep should find things a
block-by-block pass cannot, because it sees blocks next to each other.

## Before

```
channel_transport.dart   303 doc lines / 1396 total
blocks over 9 lines       12
core/lib/src total      4281
```

## Mechanism

Seven blocks were narrative — the ghost-id flood in numbers, the reconnect
trace, the 186x probe that measured the wrong side, the deadline-abort ledger.
Each keeps its invariant and loses its evidence.

**And the sweep found a defect that block-by-block could not.** At line 678 the
doc comment for `_validateInbound` — *"Checks peer-supplied metadata against the
policy…"* — ran straight into a second comment about `_maxPolicyViolations`,
with no declaration between them. Both were attached to the CONSTANT:
`_validateInbound` had no doc at all, and the constant's read as if the first
half described it.

Only adjacency shows that. Reading one block at a time, each half is coherent.

## After

```
channel_transport.dart   245 doc lines   (-58)
core/lib/src total      4223             (-207 since 293's baseline of 4430)
```

`_validateInbound` now carries its own comment; `_maxPolicyViolations` carries
only what bounds it.

Kept as invariants: refuse at the cap and never evict, because evicting drops a
live stream's credit and a ghost flood could push a real stream out of its own
window; connection credit is repaid only by consumption, so a consumer that
never reads loses it permanently and connection-wide; `lastIssuedStreamId` must
survive `close()`, since the wrapper learns of the drop BY the close; ordering
cannot be detected in `_rememberFinished`, so the set is bounded instead.

Kept as a warning, because it would be re-derived wrongly otherwise: measure the
ghost-id flood with SEPARATE policies per end — one shared policy fills the
sender's own credit map and reports 186x that is self-inflicted.

## Canary

The analyzer over `lib` plus the suite; `public_member_api_docs` witnesses the
public members only, and most of what moved here is private. Stated as in 295
rather than implied.

## Gate

`melos run analyze` — 0 errors workspace-wide. `rpc_dart` suite green.
`fvm dart format lib` — 0 changed.

## Not fixed

Queue: `base_processor.dart` 227, `responder_pipeline.dart` 270 (partly done),
`context.dart` 176, `rate_limiter.dart` 161, `security_policy.dart` 151.

Four packages of the mandate are untouched, and the order is the owner's:
websocket, http, isolate, http2 — after core.

## Links

RPC-23 (`applied:` gains 296). First round at the file-sized unit; the defect it
found is the argument for that unit.
