---
round: 297
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 297 — the detector counted a third

## Target

`base_processor.dart`, next by RPC-23's ranking. It did not stay the target: the
owner said mid-round that the mandate covers `//` as well as `///`, and
re-measuring on that basis showed the lens had been ranking — and reporting
finished — on a third of the evidence.

## Hypothesis

If the narrative is what inflates a file, it should not care which comment
syntax carries it. RPC-23's detector cared.

## Before

```
                             ///    all comments   total   ratio
base_processor.dart          227             455    1785   25.5%
channel_transport.dart       245             564    1338   42.2%   <- "done" in 296
responder_pipeline.dart      270             568    2060   27.6%   <- "done" in 295
transport.dart               212             236     533   44.3%   <- "done" in 294
security_policy.dart         151             179     366   48.9%   <- "done" in 293

core/lib total              4223            6539   23718   27.6%
```

The `///` baseline the mandate started from was 4430 in 24049, **18.4%**. The
real figure was **27.6%**, and every file rounds 293-296 reported finished still
sat at 42-49% comment.

## Mechanism

The narrative does not live in the doc comment. It lives in the `//` block
INSIDE the method, next to the line it explains — which is exactly where a
measurement table ends up, because that is where the author was standing when
they learned it. `channel_transport.dart`'s 186 MiB table, `transport.dart`'s
RSS plateau, `responder_pipeline.dart`'s 789 MiB pre-method arm and its
`cs:6:x|x|y|y|z|z` trace were all inline, all untouched by a `///` sweep.

**Three adjacency defects the file-wide sweep found, none reachable block by
block:**

1. **A block duplicated verbatim.** `getMessagesForStream` carried the same
   eight lines about timer-versus-microtask delivery TWICE in a row. Both copies
   are correct, which is why nothing caught it.
2. **A doc fused to the wrong declaration**, the shape 296 found in
   `channel_transport`, again in `responder_pipeline`: `_reclaimGrace` wore
   `_onDeadlineExceeded`'s description, so the constant read as a method and the
   method's own comment started mid-argument.
3. **The same measurement written twice in one file.** The pre-method budget's
   789 MiB and the deadline reclaim's `openStreams: 30` each appeared once as a
   doc comment and once as an inline block a few hundred lines away.

A fourth, smaller: one comment cited **`":1166-1174"`** for a rule in the same
file — a line-number reference, already wrong before this round touched it.

## After

```
                             all comments   total   ratio
base_processor.dart                   295    1617   18.2%
channel_transport.dart                430    1216   35.4%
responder_pipeline.dart               461    1948   23.7%
transport.dart                        212     509   41.7%
security_policy.dart                  166     353   47.0%
protocol.dart                          85     217   39.2%

core/lib total                       6247   23360   26.7%
```

**-292 comment lines across six files**, against the -207 that rounds 293-296
moved in four.

Kept as invariants throughout: parsers must be bounded by the transport's policy
because the channel bounds only COMPRESSED bytes; metadata counts toward
`bufferedBytes` because a count-bounded queue admits thousands of frames that
weigh nothing; the responder's demand chain starts PAUSED because every handler
has no subscriber during an async prelude; both flow-control windows are charged
or neither, or a blocked send leaks credit; `_statusSeen` is gated on a local
controller because the id is the peer's choice; `wireStatusFor` is DEFAULT DENY
and must not be widened to `Exception`.

## Canary

The analyzer over lib plus the suite. `public_member_api_docs` witnesses public
members only, and most of what moved here is private or inline — so the honest
statement is that this round's canary shows the code still compiles and behaves,
not that the comments are right. Same limit as 295 and 296.

## Gate

`melos run analyze` — SUCCESS over 21 members plus `rpc_dart_wasm`.
`rpc_dart` suite: 1429 passed, 1 skipped, 0 failed.
`fvm dart format packages/core/rpc_dart/lib` — 92 files, 0 changed.

## Not fixed

Core is at 26.7% and not finished. By ratio the worst remaining are
`retry_interceptor.dart` (55.7%), `compression.dart` (50.2%),
`security_policy.dart` (47.0%), `transport.dart` (41.7%); by volume,
`responder_pipeline.dart` 461, `channel_transport.dart` 430,
`client_connection.dart` 253, `caller_pipeline.dart` 249, `rate_limiter.dart`
228, `frame_multiplexed_channel.dart` 225.

Four packages of the mandate are untouched, in the owner's order: websocket,
http, isolate, http2 — after core.

**The unit moved twice in two rounds and both times the owner moved it.** 293-295
ran at a block, 296 at a file, and at 92 files in core alone a file per round
does not finish either. From here it is a BATCH of files per round.

## Links

RPC-23 (`applied:` gains 297) — detector corrected to all comment lines, the
unit raised to a batch, and the adjacency section extended with the two new
shapes. U-22 in the catalog carried the same wrong detector and is corrected
with it.
