---
status: open
round: (not re-measured)
commit: 2e1ec7c0
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/**, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: —
reason: owner decision — the witness was deleted at the owner's instruction after failing under parallel load; the defect it guarded is fixed and now unguarded
---

# B-52 — the concurrent-reconnect witness is gone

`packages/transport/rpc_dart_http2/test/concurrent_reconnect_test.dart` was
deleted at the owner's instruction (2026-09-17) after repeatedly failing in the
workspace run. This record exists so the knowledge does not go with it.

## What it guarded

A real, already-fixed defect: two reconnects interleaving. Both discarded the
connection, both awaited the factory, both assigned `_connection`, so the second
overwrote the first — whose connection was live and no longer referenced by
anything that could close it. The sibling of `473789b9`, found by asking whether
the websocket caller's defect existed on http2 too. It did.

Measured then, through a stalling CONNECT proxy:

```
one reconnect (control) : opened=2 closed=2 live=0
two concurrent          : opened=3 closed=2 live=1
```

The fix is still in the code. It is now unwatched.

## Why it failed, which is not why it was deleted

Not the defect returning. **Isolated, the file passes in 7 seconds**; it failed
only in the parallel workspace run, at `still live after 30001ms` — the full
30-second budget, which its own message calls out as the slow-teardown reading
rather than the leak reading: *"Near the budget means a slow teardown; far below
it means a connection nothing can close."*

So the cause was the test waiting for a BUDGET to expire instead of for the
close EVENT — L-11's shape — and it was fixable in about two lines. The owner's
call was to delete rather than repair, after that was put to them.

## What would close this record

Either a rewritten witness that waits on the event with a generous ceiling, or a
decision that this class stays unguarded. Note the precedent: `1f448150` took
another test off the gate for a neighbouring 1.3% defect, so this is the second
witness in this area to go rather than be repaired — which is worth knowing
before a third.

## Owner decision

Taken: delete the test. Asked and answered on 2026-09-17, with the alternative
(rewrite the wait as an event) on the table and declined.
