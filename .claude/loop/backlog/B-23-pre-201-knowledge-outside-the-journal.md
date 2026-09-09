---
status: open
round: 234 — measured in the curate pass after it
commit: aba26aa3
paths: [packages/**]
probe: —
reason: "cost: ~30 dossiers to compare file by file, and importing a claim with no number would pass a guess off as knowledge (the B-09 objection)"
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

## What is left, and why it is a lead rather than a round

**~30 memory dossiers still hold code knowledge with numbers**, each needing a
file-by-file comparison against this corpus before anything is deleted — memory
is not in git, so a wrong judgement loses the knowledge outright. Known groups:

    per-subsystem dossiers   websocket_transport, isolate_transport,
                             wasm_transport, backpressure_flow_control,
                             performance_work, parked_streams_and_limits
    shapes with no lens yet  http2_continuation_flood (a DoS below every
                             rpc_dart limit, in package:http2 itself),
                             reconnect_state_confusion, isolate_pre_ready_window,
                             max_active_streams_not_concurrency,
                             release_gate_blind_spots
    methods, not shapes      compare_siblings_not_just_code (used in round 234),
                             lifecycle_apis_driven_twice, measure_dont_reason,
                             per_connection_defects_hidden_by_tests
                             -> these are skill `methods/` material, which is a
                                SEPARATE skill commit, not a project one
    partially migrated       unbounded_inbound_buffers: RPC-17 owns the shape;
                             still unhomed are the by-side draining rule,
                             `preMethodBufferedBytes`, and the "the platform
                             could do what the dependency could not" lesson

**The four "methods, not shapes" entries are the highest value left**: they are
how this repo's defects get found at all, they generalise past this project, and
`curate` rule 7 already routes them — `methods/` or a pack.

## Owner decision

—
