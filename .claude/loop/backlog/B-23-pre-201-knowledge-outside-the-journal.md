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

**The six architecture notes go into the repository as docs** (round 247) —
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
