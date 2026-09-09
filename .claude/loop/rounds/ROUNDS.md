# Round journal

What a round is and how it links to the rest — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/round.md`.

**The next round's number is the highest here plus one.** That is the only
source: not memory, not a commit message, not the user's words.

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
