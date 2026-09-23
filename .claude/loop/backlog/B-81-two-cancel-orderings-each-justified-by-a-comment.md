---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
probe: —
reason: cost — split out of B-70 item 6; one of the two comments describes the other's bug, which makes this a hang, not a style question
---

# B-81 — two cancel orderings, and one comment describes the other's bug

Two sites send a cancellation notice and then tear down, in opposite orders, and
**each carries a comment defending itself**:

```
  base_processor.dart:1377   sends the notice `unawaited`, because "Awaiting the
                             notice first meant a send that never completed took
                             the local error with it -- and the `try` below
                             catches a throw, not a hang"

  unary/caller.dart:615      `await cancellationNotice` in `finally`, before
                             releaseStreamId, defending itself with
                             "_notifyPeerOfCancellation never throws"
```

**"Never throws" is not "never hangs", and the sibling's comment names the exact
transport class that hangs that way.** So one of these two comments is an
argument against the other, written by someone who had only one file open.

This is L-16's shape — copy what the sibling AVOIDS — and RPC-23's: a comment
justifying deliberateness is a lead, not a closed door (U-01).

Bench: a transport whose send never completes, driving a cancel through each of
the two paths. The reading is whether `cancel()` returns. An in-memory pair will
not produce it; the hang needs a send that parks, so borrow P-58's shape.

Expected outcome if the claim holds: `base_processor`'s path returns and
`unary/caller`'s does not. If both return, the hanging transport class named in
the comment no longer exists and this closes as a negative with that fact
recorded.

## Owner decision

—
