---
file: packages/core/rpc_dart/.dart_tool/probe/b124b_application_error_logging.dart
round: 516
commit: 25093e53
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/core/protocol.dart]
status: valid
---

# P-153 — what does an application status log?

## Why it exists

B-124 bundles two claims. Round 515 could not build a witness for the flooding half
and said so. This is the other half, and it was chosen precisely because it needs no
peer-reachability argument: "an application NOT_FOUND reads as an incident" is a
question about LEVELS, so one failing call settles it.

## The harness

One unary call per arm, with a counting `LogController` on EACH endpoint, printing
every record at `warning` or above with its scope and message.

**Counted by overriding `LogController.add`, not by subclassing `LogScope`.** That is
the method round 515 paid for: `LogScope.child()` constructs a plain `LogScope`, so a
subclass's overrides vanish as soon as the code derives a scope — and both endpoints
here do (`rpc.caller.UnaryCaller`, `rpc.responder.Svc.missing.UnaryResponder`). `add`
also runs before filtering, so it answers "did the code decide to log".

## The numbers (round 516)

```
                               before                    after
a handler throws NOT_FOUND     caller 2, responder 1     caller 0, responder 0
a call that succeeds           caller 0, responder 0     caller 0, responder 0
a handler throws INTERNAL      caller 2, responder 1     caller 2, responder 1
a handler throws StateError    caller 2, responder 1     caller 2, responder 1
```

The two caller records before the fix, for one ordinary answer:

```
error  rpc.caller.UnaryCaller  gRPC error: 5 - no such record [streamId: 1]
error  rpc.caller.UnaryCaller  Unary call /Svc/missing failed [streamId: 1]
```

## Measures

Records at `warning` or above, per side, per call. The scope and message are printed
because the count alone does not say which site fired — and the two caller records
came from different sites, which is what made the duplication visible.

## Control

**Three, and two of them run the OTHER way.**

A successful call must produce zero, or the counts mean nothing.

INTERNAL and a bare `StateError` must still produce records after the fix — without
them, silencing every log would pass the witness perfectly. They are also what pins
the two halves of the classification: a status that IS a fault, and a throw carrying
no status at all to classify.

## What it establishes, and what it does not

Establishes: one application NOT_FOUND produced three `error` records across both
sides, two of them on the caller from separate sites. After the fix it produces none,
while a genuine fault still produces the same three it always did.

**Does NOT remove the caller's duplication for genuine faults**, and the after-table
shows that plainly: `caller 2` for INTERNAL. The two records carry different
information — one the status and message, the other the method path and a stack trace
— so they are not pure duplicates, and collapsing them was left undone rather than
done silently.

Does NOT cover the streaming shapes. `StreamProcessor.sendError` is named in the same
lead and only the unary paths were varied here.

## Reading

rpc_dart — **counts by overriding `LogController.add`, which is the method
round 515 paid for**: `LogScope.child()` returns a plain scope, so a subclass
override is lost wherever code derives one, and both endpoints here do. Prints
the SCOPE and MESSAGE, not just a count — that is what showed the caller's two
records came from different sites rather than one firing twice. **Two of its
three controls run the other way**: INTERNAL and a bare `StateError` must
still log, because silencing everything would pass the witness perfectly.
