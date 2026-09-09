---
status: open
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_isolate/lib/**]
probe: —
reason: the family sweep happened off-journal and isolate was not part of it; the price is a leaked isolate, not a socket
---

# B-04 — isolate: unaudited `Future.timeout` sites

The class "a timeout abandons the wait, not the work" has been swept across the
family, but the sites in `rpc_dart_isolate` were never checked. The price here
is **a leaked isolate rather than a socket**: the isolate lives on, holds ports
and keeps the process from exiting.

Lens: `../lenses/RPC-14-timeout-abandons-work.md` — its `swept here` status has
an exception for exactly this lead.

## Owner decision

—
