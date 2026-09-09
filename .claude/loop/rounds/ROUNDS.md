# Round journal

What a round is and how it links to the rest — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/round.md`.

**The next round's number is the highest here plus one.** That is the only
source: not memory, not a commit message, not the user's words.

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
