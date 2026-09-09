---
status: closed (round 223) — all four sites swept and guarded
round: 223
commit: 0e7b984a
paths: [packages/transport/rpc_dart_isolate/lib/**]
probe: —
reason: swept in round 223 — all four sites guarded, nothing abandoned
---

# B-04 — isolate: unaudited `Future.timeout` sites

The class "a timeout abandons the wait, not the work" had been swept across the
family, but the sites in `rpc_dart_isolate` were never checked. The price here
would have been **a leaked isolate rather than a socket**: the isolate lives on,
holds ports and keeps the process from exiting.

**Closed by round 223.** All four sites swept and clean — the site table and the
one deliberate empty `onTimeout` are recorded on the lens,
`../lenses/RPC-14-timeout-abandons-work.md`, whose `except isolate` exception is
removed accordingly.

## What the closure leaves behind

The guards are correct and **untested**: removing `teardownStartup()` from the
failed-handshake catch leaves a stuck isolate and its ports behind, and the
isolate suite still passes (`+73`). That is the same finding round 222 made in
core, and the two together are `../lessons/L-04-a-guard-with-no-witness.md`.

Not opened as a new lead, because the harness that would express it already
exists in this package — `close_releases_the_isolate_test.dart` asserts on a
SUBPROCESS's exit — and the extension is small: fail the handshake in the child,
then assert the child exits rather than hanging on a live isolate. Worth doing
alongside `../backlog/B-20-detached-guard-has-no-witness.md`, which needs the
same shape for core and is now owner-approved.

## Owner decision

—
