# Round journal

What a round is and how it links to the rest — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/round.md`.

**The next round's number is the highest here plus one.** That is the only
source: not memory, not a commit message, not the user's words.

- **[250](250-the-ordering-coincidence-becomes-an-invariant.md)** FIXED, rpc_dart — the frame channel's inbound controller buffers like the other six; shipped with NO canary, on the owner's decision, and the record says so
- **[268](268-three-flags-three-meanings.md)** CLEAN, rpc_dart — RPC-19 re-swept over its one moved file: zero lines in that diff touch a lifecycle flag, and `_closed` / `_isStopped` / `_disposed` still mean three different things
- **[267](267-the-documentation-b-23-was-hiding.md)** FIXED, rpc_dart — B-23's architecture half: an inventory made from file names predicted five duplicates, the reading gave two additions and two documentation defects. Three docs shipped, one repaired (it taught `RpcLogger`, which does not exist), four notes retired
- **[266](266-the-guard-that-owed-the-pool-forever.md)** FIXED, rpc_dart — a paused consumer never receives `done`, so it never repaid the connection pool; `_fcForget` now repays unconditionally. 1024 -> 3072 KiB, wedged at call 4 -> never. One line, after eighteen rounds proving the danger it guarded against does not exist
- **[249](249-the-mark-works-and-was-reverted.md)** DEFERRED, rpc_dart — B-22's mark built and measured lifting the wedge (1024 -> 3072 KiB, suite green), then reverted: two of the three canary arms, and the missing one guards an inflating window
- **[248](248-the-obvious-fix-for-b-22-is-wrong.md)** DEFERRED, rpc_dart — B-22's mechanism localised to one condition, and the one-line fix it suggests refuted: it would credit the connection twice
- **[247](247-b-11s-blocker-still-holds.md)** DEFERRED, rpc_dart — B-11's blocker re-checked and CONFIRMED: no latency helper exists anywhere in the tree, so the fourth bench attempt must build the delayed link first (~25 lines, `_ManualChannel` as the model)
- **[246](246-no-new-timeouts-to-abandon.md)** CLEAN, rpc_dart — RPC-14 re-swept over its diff: zero new `.timeout(` sites, and the two awaits added on resource-holding paths are guarded, one of them being the lens's own adopt-the-abandoned-future fix
- **[245](245-the-dimension-236-excluded.md)** FIXED, rpc_dart — metadata weighed zero against the unlistened queue's byte bound: 4096 frames retained 256 MiB against a 16 MiB cap, now 255 and 15.9 MiB
- **[244](244-the-parked-sender-still-wakes.md)** CLEAN, rpc_dart — RPC-09 re-swept over 6 moved files: close() still wakes every parked sender, and round 240's buffering turned out to have SHRUNK the hazard this round set out to attack
- **[243](243-the-trailer-cap-held.md)** CLEAN, core and the three transports — RPC-02 re-swept over 10 moved files: every message-carrying trailer still capped, including both refusal paths added since
- **[242](242-the-callback-that-ends-the-isolate.md)** FIXED, rpc_dart — a throwing `onStateChanged` reached the root zone AND aborted the connect loop before it built anything: unhandled 1 -> 0, transports 0 -> 2
- **[241](241-the-discard-that-sometimes-does-not-land.md)** DEFERRED, rpc_dart_http2 — a sequential reconnect orphans a DISCARDED connection about 1.3% of the time; the candidate fix could not be witnessed, so it was reverted
- **[240](240-the-buffer-drained-into-nothing.md)** FIXED, rpc_dart — the reconnect proxy drained every transport's inbound buffer into a controller nobody was listening to
- **[239](239-finishing-what-234-opened.md)** CLEAN, no packages — finishing what 234 opened: six more memory dossiers into the journal, and the note graph repaired
- **[238](238-the-recovery-api-works-more-than-once.md)** CLEAN, the four transports and core — no third instance of the conflated lifecycle flag; the ablation is what makes that mean something
- **[237](237-the-dependency-shared-what-we-copied.md)** FIXED, rpc_dart_http2 — the dependency shared what we copied: 63 KiB of header block became 258 MiB in the adapter
- **[236](236-the-bound-that-counted-the-wrong-thing.md)** FIXED, rpc_dart and the three transport packages — the pending queue counted events while the damage was bytes: 4096 x 16 MiB admitted
- **[235](235-the-one-hop-nobody-guarded.md)** FIXED, rpc_dart — the one hop nobody guarded: an unguarded cancel between two guarded closes
- **[234](234-the-reconnect-nobody-drives.md)** FIXED, rpc_dart and rpc_dart_websocket — the reconnect nobody drives: a peer-started drop rewound the stream-id cursor
- **[233](233-websocket-rescan-the-first-third.md)** CLEAN, rpc_dart_websocket — websocket rescan, the first third
- **[232](232-the-selector-read-an-archive-as-a-decision.md)** FIXED, rpc_dart — the selector read an archive as a decision
- **[231](231-the-two-candidates-are-one.md)** DEFERRED, rpc_dart — the two candidates are one
- **[230](230-the-last-round.md)** CLEAN, rpc_dart — the last round; the swallowed grant failure is unreachable and load-bearing
- **[229](229-a-zero-grant-is-not-silence.md)** FIXED, rpc_dart — a zero grant is not silence
- **[228](228-the-branch-206-did-not-cover.md)** DEFERRED, rpc_dart — the branch round 206 did not cover
- **[227](227-the-web-guard-does-catch-it.md)** CLEAN, rpc_dart and rpc_blob — the web guard does catch it
- **[226](226-close-the-gate-over-wasm.md)** FIXED, rpc_dart_wasm — close the gate over wasm
- **[225](225-the-guard-nothing-reaches.md)** CLEAN, rpc_dart — the guard nothing reaches
- **[224](224-refuse-a-transport-that-cannot-carry-the-watermark.md)** FIXED, rpc_dart — refuse a transport that cannot carry the watermark
- **[223](223-the-isolate-exception-closed-and-a-pattern.md)** CLEAN, rpc_dart_isolate — the isolate exception closed, and a pattern
- **[222](222-every-site-guarded-the-guard-untested.md)** CLEAN, all five transport packages — every site guarded, and the guard untested
- **[221](221-the-sweep-that-could-not-see-a-hang.md)** CLEAN, rpc_dart and rpc_dart_http2 — the sweep that could not see a hang, now can
- **[220](220-the-package-the-gate-cannot-see.md)** CLEAN, rpc_dart_wasm — the package the gate cannot see
- **[219](219-what-the-web-gate-actually-covers.md)** CLEAN, rpc_dart — what the web gate actually covers
- **[218](218-generation-tagging-cannot-work.md)** DEFERRED, rpc_dart — generation tagging cannot work, and the measurement says so
- **[217](217-a-decorator-erases-the-stream-id-watermark.md)** DEFERRED, rpc_dart — a decorator erases the stream-id watermark
- **[216](216-a-refusal-survives-its-own-policy.md)** CLEAN, rpc_dart and rpc_dart_http2 — a refusal survives its own policy
- **[215](215-the-pre-method-budget-comes-back.md)** CLEAN, rpc_dart — the pre-method budget comes back
- **[214](214-handler-slots-come-back.md)** CLEAN, rpc_dart — handler slots come back on every teardown path
- **[213](213-a-slow-handler-is-killed-not-throttled.md)** DEFERRED, rpc_dart_http2 — a slow handler is killed, not throttled
- **[212](212-a-late-grant-resurrects-a-dead-stream.md)** FIXED, rpc_dart — a late grant resurrects a dead stream's credit
- **[211](211-the-wake-is-load-bearing.md)** CLEAN, rpc_dart — the wake is load-bearing after all
- **[210](210-the-answer-does-not-wait-on-the-send.md)** CLEAN, rpc_dart and rpc_dart_http2 — the answer does not wait on the send
- **[209](209-a-decorator-can-switch-the-bound-off.md)** FIXED, rpc_dart_http2 — a decorator that declares a capability can switch the bound off
- **[208](208-refuse-instead-of-pausing.md)** FIXED, rpc_dart_http2 — refuse the stalled call instead of pausing the read
- **[207](207-http2-cancel-kills-the-connection.md)** DEFERRED, rpc_dart_http2 — cancelling a stalled http2 call kills the connection for good
- **[206](206-connection-credit-never-repaid.md)** FIXED, rpc_dart and rpc_dart_isolate — connection credit is never repaid for bytes nobody consumed
- **[205](205-policy-limits-clean.md)** CLEAN, websocket and isolate — DoS limits really do bite on the channel transports
- **[204](204-retraction-listen-onerror.md)** RETRACTED, rpc_dart, `6ae31212` — the request stream carries cancellation, so listen needs onError
- **[203](203-failed-fix-attempt.md)** revised by round 204, rpc_dart — an attempt to fix a defect that did not exist
- **[202](202-clientstream-cancel-claim.md)** revised by round 204, rpc_dart — the claim that cancelling a clientStream kills the process
- **[201](201-cancel-told-server-first.md)** FIXED, rpc_dart, `fdab119f` — a cancelled call told the server before telling itself
