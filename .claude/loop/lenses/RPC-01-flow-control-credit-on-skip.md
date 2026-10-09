---
refines: U-07
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: there is credit accounting released on message delivery
breaks: a wedged connection — a hang.
applied: [206, 207, 208, 212, 213, 228, 229, 230, 231, 281, 282, 366, 445, 469, 475, 497, 558, 738]
status: confirmed (round 558)
rank: 11
---

# RPC-01 — Flow-control credit on the skip path

## Shape

A frame is refused or skipped without becoming a message, while the credit
return hangs on the "message delivered" event.

Round 206 widened this: the frame does not have to be SKIPPED. It is enough that
it is delivered to a consumer that never takes it, because the credit return
hangs on the same event either way. And where there are two levels of
accounting, ask the question once per level — a reclaim at one is not a reclaim
at the other.

## Detector

`_fcOnConsumed` and every one of its callers; every place a frame is dropped
before it becomes a message; `sendMessage` as the sole consumer of credit. Then,
per level: what reclaims credit at teardown, and is the RETURN path gated on a
flag that belongs to the other level?

Also: which operations are not charged at all (they pass a gate meant to make
things wait); what the admission gate compares (sign or fit) and whether it
knows who is queued; and everything that can touch a park queue.

## Ask

Will the credit the sender has already charged itself ever come back? And its
twin for the bookkeeping: does the record of it go away?

## Evidence

An 8 MiB window with 2 MiB per refusal: it wedged on exactly the fourth refusal.
Metadata frames are outside flow control — checked, not assumed (round 162,
off-journal).

- **Round 206** — the CONNECTION pool: 1 MiB pool, 256 KiB per call; a receiver
  that binds and never reads dies after 4 calls (1024 KiB, the pool exactly).
  `_fcForget` reclaimed only the per-stream window, and gates tested
  `flowControlWindowBytes` alone. Both fixed. `../probes/P-01-connection-window-debt.md`.
- **Round 207** — on http2 rpc_dart throttled by pausing package:http2's
  subscription; one cancel of a stalled call (68 KiB) hung every later call. A
  bound implemented by NOT READING is a bound held in the layer below; prefer a
  bound you can account for yourself. `../probes/P-02-http2-aborted-call-pool.md`,
  `../backlog/B-12-http2-cancel-kills-the-connection.md`. Other transports
  delegate to core: `RpcChannelTransport` is the only `IRpcFlowControlled`
  under websocket and isolate.
- **Round 208** — Round 208 fixed it by the owner's choice: never stop reading,
  keep `flowControlWindowBytes` as the budget, and FAIL a call past it. All four
  arms recover; the bound bites at 4171 KiB vs 15291 KiB unbounded.
- **Round 212** — a LATE peer grant after `_fcForget` writes the entry back;
  capped, but once the cap fills with dead ids `initialSendWindowBytes` stops
  applying.
- **Round 228** — first real sweep since 213: a consumer that binds and PAUSES
  satisfies `hasListener`, never cancels, wedges at call 4 (1024 KiB). A fix
  that hands responsibility to a callback inherits that callback's reachability.
  Deferred: `../backlog/B-22-paused-consumer-never-repays-the-pool.md`,
  `../probes/P-11-connection-debt-with-a-paused-consumer.md`.
- **Round 229** — lead B-05: `_fcNotePeerGranted` was gated on `parsed > 0`, so a
  first grant of ZERO read as legacy: 800 KiB accepted against a 64 KiB window
  (12.5x), 16 KiB after the fix. The VALUE of a grant and the FACT of one answer
  different questions; reachable only from a foreign peer.
  `../probes/P-12-zero-grant-reads-as-legacy.md`.
- **Round 445** — of four send paths that end a stream, `sendDirectObject(end)`
  overtook a parked send (`finishSending` got the rule in round 366,
  `sendMetadata(end)` in 663cccec). Being outside the accounting is the
  qualification, not the exemption: it never calls `tryConsume`.
  `../probes/P-99-which-ending-paths-wait-for-a-parked-send.md`; B-88 holds the
  path no witness reached.
- **Round 469** — `tryConsume` admits on `credit > 0` and never consults
  `_sendWaiters`; `wakeAll()` is synchronous, the waiter's continuation a
  microtask, so a fast-path send steals the credit. A gate that admits on a SIGN
  rather than a FIT has no queue, and a wake is not a handover; an interleaving
  one microtask wide is CONSTRUCTED, never raced for.
  `../rounds/469-the-void-arm-repaired.md`, `../probes/P-118-the-turn-a-grant-lands.md`.
- **Round 475** — reached 469's window at transport level via a
  `StreamController(sync: true)` inbound: a caller gets inside a callee's turn by
  being CALLED. When a round stops on "unreachable", re-check which DIRECTION it
  measured. A guard on a deliberately synchronous path is conditional
  (`_parkedSends.containsKey(streamId)`, not awaiting `_claimEnding`).
  `../rounds/475-inside-the-waking-turn.md`, `../probes/P-119-inside-the-waking-turn.md`.
- **Round 497** — absolute numbers misled (producers run ahead by design,
  `checked/C-19`); shrinking the window 64-fold moved codec 32x and zeroCopy not
  at all. When the hypothesis is "this limit does not apply here", vary the
  LIMIT; and read the control first, since it can show the bench cannot see the
  defect. DEFERRED: a nominal weight or parking on credit (reversing rounds 208
  and 214). Both are the owner's.
  `../probes/P-135-does-the-window-reach-a-direct-object.md`,
  `../rounds/497-vary-the-limit-to-see-if-it-is-the-limit.md`, B-106, B-195.
- **Round 558** — a send parked on the HTTP/2 window lost its 64 B payload to
  `endStreamNow()` while `add` returned TRUE. A park is a queue, so everything
  that can touch it must respect its order; the silent part is the defect (make
  an undeliverable send throw); one witness per mechanism.
  `../rounds/558-the-half-close-overtook-the-payload.md`,
  `../probes/P-183-what-reaches-the-wire-when-a-parked-send-meets-a-half-close.md`, B-184.
