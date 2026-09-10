---
round: 299
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 299 — a token and its generator

## Target

Five more core files at the batch unit: `context`, `call_scope`,
`buffered_broadcast`, `metadata`, and a second pass over `responder_pipeline`'s
handler-slot and client-cancellation blocks.

## Hypothesis

298 found the adjacency shape for the third round running and left the lens
unchanged, predicting it would keep appearing. A fourth instance would make it
the most reliable finding of the mandate.

## Before

```
                        comments   total
context                      203     728
call_scope                   122     285
buffered_broadcast           105     284
metadata                     127     442
responder_pipeline           478    1970

core/lib total              6054   23167
```

## Mechanism

**A fourth fused doc, and it inverted a security claim.** In `context.dart`,
`_uniqueToken`'s description — *"generates a 16-byte url-safe token… the first
12 bytes are random"* — was attached to `_strongRng`, running straight into that
field's own doc with no declaration between them. So `_uniqueToken`, the
function that mints every request and trace id, had NO doc at all, while the
field's began by describing something else.

Buried in the fused block was the fact that matters: `Random.secure()` **throws
on any node runtime**, so every id there comes from a non-cryptographic
generator. That sat under a heading about a different member, behind two
paragraphs of measurement. It is now the second line of `_strongRng`'s doc,
where someone deciding whether these ids can carry security weight will see it.

Four files, four rounds: `channel_transport` (296), `responder_pipeline` and
`getMessagesForStream` (297), `compression` (298), `context` (299).

Other cuts followed the established rule — keep the invariant, drop the run that
proved it: `BufferedBroadcastController`'s 48-line class doc (the both-dimensions
argument survives, the retention table goes), `forTrailer`'s trimming rule,
`statusDetailsBin`'s unpadded-base64 rule, the call-scope disposer timeout, and
the handler-slot charge point.

## After

```
                        comments   total
context                      181     694
call_scope                   115     279
buffered_broadcast            89     265
metadata                     111     423
responder_pipeline           474    1963

core/lib total              5989   23078
```

**-65 comment lines.** Core is at **25.9%**, from a true baseline of 27.6% at
297. Total across 297-299: **6539 → 5989, -550 lines**, seventeen files.

## Canary

Analyzer over lib plus the suite — the same honest limit as 295-298: it shows
the code compiles and behaves, not that a comment is right.

## Gate

`melos run analyze` — no issues. `rpc_dart` suite: 1429 passed, 1 skipped, 0
failed. `fvm dart format` — 92 files, 0 changed.

## Not fixed

`responder_pipeline` (474) and `channel_transport` (430) hold a third of what is
left between them, and both have had two passes; what remains in them is
invariant rather than narrative, so the next pass there will yield much less
than the first.

Four packages of the mandate are still untouched, in the owner's order:
websocket, http, isolate, http2. **Core is close enough that the next round
should start on websocket rather than grind core past diminishing returns.**

## Links

RPC-23 (`applied:` gains 299). The adjacency rule now has four instances and
needs no further amendment; what 299 adds is that a fused doc can HIDE a
security-relevant fact, not merely misattribute a description.
