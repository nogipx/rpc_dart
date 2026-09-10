---
status: open
round: 234 — measured in the curate pass after it
commit: aba26aa3
paths: [packages/**]
probe: —
reason: "cost: ~30 dossiers to compare file by file, and importing a claim with no number would pass a guess off as knowledge (the B-09 objection)"
continuation: yes
---

# B-23 — The pre-201 knowledge that never entered the journal

## The measurement

Private memory holds **52,203 words across 51 files**; this corpus holds
**54,792**. Two knowledge bases of the same size, and until round 234 nothing
said which owned what.

The first hypothesis — that they duplicate each other — is **wrong, and was
measured wrong**. Greps for the memory corpus's own distinctive strings return
nothing here:

    CONTINUATION        0 hits        756 MiB / 192 MiB   0 hits
    check before await  0 hits        pre-ready           0 hits
    header block        0 hits        one battery         0 hits

What actually happened is a seam. `checked/` DID import the pre-201 **negatives**
(C-02 round 46, C-03 round 77, C-04 round 106, C-15, C-16, C-17, C-18). The
pre-201 **shapes, findings and methods** stayed outside — so `loop.py next`
could not route to them, `stale` could not age them, and `lint` could not see
them. That is invisible rather than merely untidy: a shape with no lens is one
the loop will never take.

## Done in the curate pass after 234

The two shapes whose absence cost the most, verified against current code before
being written down (both are live, with in-code comments and regression tests):

- `../lenses/RPC-16-check-before-await.md` — four fixed instances by sha, the
  three measurement traps, the root-zone `finish()` gotcha. Its source memory
  file was fully covered and has been retired.
- `../lenses/RPC-17-limit-fires-after-residency.md` — 192 MiB into 756 MiB RSS,
  2071x through permessage-deflate, 470x through a gzip codec, plus the
  measured-clean list. No catalog shape covers it; a `catalog/` candidate.

And the boundary is now written down in `../LOOP.md` ("Where knowledge lives"),
which is what stops the two corpora drifting apart again.

## Second pass, same session — the shapes and methods are in

Six more records, each verified against current code before being written:

    RPC-18  the dependency buffers below every limit you own (CONTINUATION
            flood: 64 MiB starved every other client; the caller side worse
            at +194.3 MiB)
    RPC-19  one flag meaning both "closed" and "disconnected"; the give-away
            is a recovery API that works exactly once
    RPC-20  the window before the first listener (200/200 chunks against an
            8 KiB window, 8/200 after)
    RPC-21  drive the lifecycle twice -- the lens C-06 itself had been asking
            for, since it recorded U-15 as having no lens
    L-07    instrument every hop at once (3 of 4 attempts lost to arguing)
    L-08    a per-test connection cannot see a per-connection defect
    C-27    "keep calling on one connection", clean on the other three
    C-28    the sibling battery's clean rows, incl. the CORS/CSRF gate

`RPC-08` also gained the owner's round-101 parity qualifier — match BEHAVIOUR
not code, every transport except `rpc_dart_http`, a code-shape difference is a
lead — which had been sitting in memory where no round would have found it, and
which governs how the parity lens may be used at all.

## Round 239 — six more, and the graph repaired

The first round the selector routed here on its own, once `continuation: yes`
and the shortlist existed. Closed: `leak_audit_coverage` -> C-18 (a 4-line stub
that now carries the 2996-entry defect and the 38-case matrix),
`which_transport_uses_which_layer` -> RPC-10, `web_dart2js` -> RPC-07,
`future_timeout_abandons_work` -> RPC-14, `client_stream_cancel...` (already
whole in rounds 202-204), `closed_transport_leniency_contract` -> the new C-30.
`backlog_proto_contract_generator` was reclassified as roadmap and stays.

    memory notes   41 -> 34      queue   27 -> 21
    dangling links 19 -> 0       orphans 10 -> 0

**The migration broke the note graph twice before anyone noticed** — see
`../lessons/L-09-a-delete-has-an-inbound-half.md`. Any further pass must repoint
inbound links after deleting, and count inbound edges after touching the index.

## What is left, and why it is a lead rather than a round

**21 files**, each needing a comparison against this corpus before anything is
deleted — memory is not in git, so a wrong judgement loses the knowledge
outright. The live list is the "Still to move" section of the store's own
`MEMORY.md`; the groups are:

    per-subsystem dossiers   websocket_transport, isolate_transport,
      (6)                    wasm_transport, backpressure_flow_control,
                             performance_work, release_gate_blind_spots
    have a loop home,        stream_ids_restart_on_reconnect (RPC-03),
      needs a check (6)      capability_interfaces_hidden_by_wrappers (RPC-04),
                             unhandled_async_error_class (RPC-13),
                             closed_transport_error_type_split (B-08),
                             response_metadata_is_dropped (B-01),
                             real_grpc_client_interop (C-15)
    no home yet (2)          unbounded_inbound_buffers -- RPC-17 owns the shape;
                             still unhomed are the by-side draining rule,
                             `preMethodBufferedBytes`, and "check whether the
                             PLATFORM can do what the dependency cannot".
                             Plus core_audit_2026-06-wip
    architecture, not        core_types, core_design, transport_architecture,
      measurement (6)        logger, rpc_dart_log, grpc_compat

**The architecture six are the ones to decide before touching**: they describe
what the code IS rather than anything measured, which is the repo's own docs'
job and not the journal's. Moving them into `.claude/loop/` would repeat the
category error the first two passes spent their effort undoing. That is an
owner's call, not a round's.

The "methods, not shapes" group named here in earlier passes is DONE — U-14 and
U-15 already held two of them, and L-07 and L-08 were filed for the other two.

## Owner decision

**Inventory first, then decide per note** (round 262). Given round 261's finding
that this is a merge rather than a move, the owner narrowed the earlier
authorisation: one round answers, for each of the six, whether `docs/` already
says it — add, contradict, or repeat — and a note that only REPEATS is deleted
rather than moved. Nothing is written into `docs/` before that list exists.

**The six architecture notes go into the repository as docs** (round 247,
narrowed above) —
core_types, core_design, transport_architecture, logger, rpc_dart_log,
grpc_compat. They describe what the code IS, which is documentation's job rather
than the journal's, and in the repo they become reviewable in diffs and age
visibly instead of silently.

Two conditions the migration carries, both from this lead's own history:

- **Check each against the implementation before it lands.** Rule one applies
  in full: prose about code is a secondary source, and these were written
  against a tree that has moved by 47 rounds. What the code contradicts is
  edited or dropped, not transcribed.
- **The delete has an inbound half** (L-09). After each file moves, grep the
  remaining notes for its name in double brackets and repoint every link at the
  new path.

That leaves the per-subsystem dossiers as the rest of B-23; they split into
negatives and lens evidence the way the earlier six did.

### Scoped in round 261, and it is bigger than "move six files"

Two facts the decision did not have:

- **`grpc_compat` alone is 459 lines**, and the decision requires each claim
  checked against the implementation before it lands — these were written
  against a tree that has moved by 47 rounds. That is a round per note at least,
  not six notes in a round, and the checking is the whole cost.
- **`docs/` already exists and overlaps**: `architecture.md`,
  `core-concepts.md`, `core/`. So this is a MERGE, not a move. Dropping
  `transport_architecture.md` beside an existing `architecture.md` would leave
  two documents answering the same question, which is the duplication the
  one-home rule exists to prevent — and worse in the repo than in private
  notes, because readers trust what is committed.

### First cut of the inventory — round 268

`docs/` is not a stub. It is a documentation set:

```
docs/architecture.md          522 lines
docs/core-concepts.md         320 lines
docs/getting-started.md, index.md
docs/core/          rpc_dart.md, compression.md, generator.md, opentelemetry.md
docs/transports/    http.md, http2.md, websocket.md, isolate.md, inmemory.md,
                    turn-relay.md, index.md
docs/guides/        rpc-lifecycle.md, streaming-patterns.md, error-handling.md,
                    context-and-metadata.md, routing-and-composition.md,
                    diagnostics.md, testing-and-debugging.md
docs/ru/, docs/plans/, docs/assets/
```

**Provisional mapping of the six notes onto it**, to be confirmed note by note:

```
note                    the docs that already cover the ground
core_types              docs/core/rpc_dart.md, core-concepts.md
core_design             architecture.md, core-concepts.md
transport_architecture  architecture.md, all of docs/transports/
logger                  guides/diagnostics.md, core/opentelemetry.md
rpc_dart_log            guides/diagnostics.md
grpc_compat             nothing obvious — the likeliest genuine ADDITION
```

**`grpc_compat` confirmed as the genuine gap — round 269.** Measured against
`docs/`:

```
files mentioning gRPC at all                        8
files naming grpc-status / -message / -timeout      1  (transports/http.md, twice)
files naming any x-rpc-* header of this library     0
```

Eight files say "gRPC"; exactly one names a wire header, twice, in passing; and
NOTHING documents which `x-rpc-*` headers this library adds that gRPC does not
know — which is precisely the question a user hits when they put rpc_dart behind
a real gRPC proxy. That is the note's core subject and it is absent.

**The verified core of that merge — round 270.** Taken from
`core/rpc_headers.dart`, not from the note, per rule one:

```
x-trace-id              :53
x-request-id            :56
x-route-service         :59
x-client-cancelled      :62
x-cancellation-reason   :65
x-rpc-window-update     :76    flow control, per stream
x-rpc-conn-window-update:88    flow control, connection-wide
```

Seven headers gRPC does not define, none of them documented anywhere in
`docs/`. Two of them carry the flow-control protocol that a plain gRPC peer
knows nothing about, which is exactly the interop question — an intermediary
that strips unknown metadata silently disables flow control rather than failing
visibly.

**Written and shipped in round 271**: `docs/transports/grpc-compat.md`, linked
from `docs/transports/index.md`. It carries the seven headers, and the part that
makes it worth having — what a stripping intermediary breaks. The two
flow-control headers are the answer: remove them and a sender spends its initial
window and parks permanently, with no error and no timeout, because the
never-heard-a-grant fallback keys off silence and cannot detect a proxy that
passes the first grant and drops the rest.

**And round 272 found the deletion half is NOT a formality.** Opening
`grpc_compat` to retire it showed the note holds more than the header list: a
standing Dart<->Go interop constraint the owner has restated, and the round-101
story of how that got unblocked. Neither is in the shipped doc. The note was
therefore marked PARTLY moved, with a pointer at the top and an explicit "do not
delete this on the strength of the doc existing" — because this store is not in
git and a wrong coverage call loses the content outright.

### Two of the five read — round 273

Sizes first: `core_types` 14 lines, `core_design` 15, `transport_architecture`
27, `logger` 44, `rpc_dart_log` 79. All small; the reading is cheap and only the
verdicts matter.

**`core_types` — a list of key type names. Mostly covered, one real gap.** Its
least obvious fact, that `RpcCodec` is CBOR and not JSON, appears in four docs
files including `core/rpc_dart.md`. But `RpcPeerEndpoint` and
`IRpcMultiplexedChannel` appear ONLY in `docs/design_rpc_logger_v2.md` — a
design document, not the reference a user reads. So the note is a duplicate, and
the reading surfaced a DOCS gap rather than content to migrate: the
user-facing reference does not name the bidirectional endpoint or the
multiplexed-channel interface.

**`core_design` — not documentation at all.** Four implementation claims: the
`_OpaqueValue`/`_OpaqueCodec` bridge, `RpcStatusException` letting handlers pick
a gRPC code, a double-start warning on `RpcHttp2Server`, and a `CallProcessor`
race that was FIXED. Those are journal-shaped — findings and their fixes — not
things a user needs. Nothing here belongs in `docs/`, and the fixed race belongs
nowhere at all now.

**`transport_architecture` — round 274, and this one is a genuine ADDITION.**
`docs/architecture.md` is 522 lines and mentions `IRpcMultiplexedChannel`,
`RpcFrameMultiplexedChannel` and `RpcDirectMultiplexedChannel` **zero times**.
The note carries the three-layer model — raw byte pipe, multiplexed message
channel, transport — with the file behind each layer and the three
`RpcChannelTransport` factories. That is the shape of the code and it is
undocumented.

Checked against the implementation, as required before anything moves: the
`DirectMultiplexedChannel` sync-controller claim is still TRUE
(`direct_multiplexed_channel.dart:17`, `broadcast(sync: true)`). The same claim
about `ChannelTransport` is now FALSE — rounds 236 and 240 made its inbound
controller a `BufferedBroadcastController`. One line of five is stale, which is
about the rate this migration should expect.

So the inventory's prediction — five duplicates, one addition — was wrong:
this is a second addition, and the biggest one.

### Round 275: the `logger` note found a DOCS DEFECT, not a duplicate

`docs/guides/diagnostics.md` has a section headed **"Logging with `RpcLogger`"**,
and `RpcLogger` **does not exist anywhere in the code**:

```
grep RpcLogger  packages/core/rpc_dart/lib, rpc_dart_log/lib   0 hits
grep LogController                                             log_controller.dart
LogController in docs/guides/diagnostics.md                    0 mentions
```

The real API is `LogController` + `LogScope`, and it appears only in
`design_rpc_logger_v2.md` (a design document) and `core/opentelemetry.md`. So
the user-facing diagnostics guide teaches a removed name, and the one that
replaced it is documented nowhere a user would look.

**This is rule one exactly** — prose about code, gone stale, and a divergence is
a defect. It is also NOT B-23's: the note is what surfaced it, but the defect is
in the repository's own documentation and outlives any decision about private
memory. It needs its own round: rewrite that section against
`lib/src/logger/`, using the note's architecture summary as the outline and
verifying each name.

The note itself is therefore a third ADDITION rather than a deletion — after the
guide is fixed, what remains of it (the pipeline order, the sealed `LogRecord`
variants, the extension points) is the outline that fix should follow.

Verdicts so far: `grpc_compat` partly moved, `core_types` and `core_design`
deletions, `transport_architecture` to be merged into `docs/architecture.md`
after its stale line is dropped. Neither of the two deletions is a straight
duplicate the way the inventory guessed — one leaves a docs gap behind it, the other was mis-filed as
architecture when it is a round history.

**That is a warning about the other five.** The inventory predicted they reduce
to duplicates of `docs/`, and the prediction was made from FILE NAMES. Each one
has to be opened and read before it is dropped; expect at least one more to
carry something the docs never said.

`grpc_compat`'s header half of B-23 is therefore DONE, from the code rather than
from the note. What remains of the note is per-header reasoning, to fold in if a
later reading finds any of it still true.

That list is the doc, and it is now checked against the implementation instead
of against a 47-round-old note. What the note may still add is the REASONING for
each, which is what needs reading when the merge is written.

So the shape of the remaining work is confirmed: five deletions and one merge,
and the merge is into `docs/transports/` rather than a new top-level file, since
that is where the two existing mentions live.

So the expected outcome is not six new files. Five of the six probably reduce to
"already said, better, in a file with an audience" and get DELETED; `grpc_compat`
is the one that may earn a place, and it is the 459-line one that needs its
claims checked hardest.

**What that changes:** the migration needs an inventory first — for each of the
six, what does `docs/` already say, and is the note adding, contradicting, or
repeating? A note that only repeats gets deleted, not moved. Nothing should be
written into `docs/` before that inventory exists, or the merge becomes a second
cleanup job.
