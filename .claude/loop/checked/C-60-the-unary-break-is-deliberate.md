---
round: 526
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
scope: the `break` after the first decoded unary response, and the reachability of the warning below it
---

# C-60 — the unary `break` is deliberate, and its warning is reachable

B-129 item 16: *"`break` after the first decoded response silently drops any further
messages in the chunk; the 'extra response' warning below it is unreachable."*

**The first half is true and is correct behaviour. The second half is false.**

## What the code does

```dart
for (final msgBytes in messages) {
  final response = _responseSerializer.deserialize(msgBytes);
  if (!completer.isCompleted) {
    pendingResponse = response;
    hasPendingResponse = true;
    break;                    // Only first response is needed for unary call.
  } else {
    _logger.warning('Extra response after call completion [...]');
  }
}
```

**The drop is the gRPC contract, not a bug.** A unary response is exactly one message;
a server sending two is misbehaving, and taking the first is what every gRPC client
does. `break` is the correct answer, and the comment says so.

**The warning is reachable**, by the path the lead did not consider: a DATA frame
arriving AFTER the status trailer has completed the call. Then `completer.isCompleted`
is true on the FIRST message of that chunk, the `else` fires, and the warning is
logged. What cannot happen is the warning firing for a second message inside a chunk
whose first message completed nothing — because `break` leaves the loop first.

So the real gap is narrower than filed: **a second response inside ONE chunk, before
the status, is dropped without a word.** Two responses split across two chunks, with a
status between them, IS reported.

## Control

The reachability claim is decided by which branch each ordering takes, so the two
orderings ARE the comparison:

- data-then-status, two messages in one chunk -> `break` on the first, second dropped
  silently, warning not reached;
- status-then-data -> `completer.isCompleted` is true, `else` taken, warning logged.

Reading one ordering alone is what produced the "unreachable" claim.

## What this does NOT establish

Nothing was RUN. This is a reading, and it is filed as a negative about the SEVERITY
claim rather than as a measurement: no probe drove a server that sends two responses in
one chunk, and no test asserts either ordering.

A round that wanted to close the remaining gap would make the drop observable — count
it, or log it once — which is a small change with no defect behind it, since dropping
is correct and only the silence is arguable.
