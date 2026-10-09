---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b143_what_an_orderly_close_logs.dart
round: 587
commit: 08d2f17c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-207 — what an orderly close logs, per in-flight call

## Why it exists

B-143's last claim: in-flight calls each log an error during an orderly close.
"Each" is the claim, so the measurement has to be a count that SCALES — one record
would be a message, N records is the defect.

## The harness

A `dart:io` server that drains every request and never answers, so N calls are
parked when `close()` lands. A `LogController` subclass counts records by level and
keeps the last error message.

`minLevel: RpcLogLevel.internal`, which is load-bearing: with the default the
guarded `internal` call is filtered, so a count of zero errors cannot be told from
a log that was DELETED rather than moved down a level.

The error count is read BEFORE the close as well, so the arm asserts that nothing
had failed yet.

## The numbers (round 587)

Before:

```
8 calls in flight   errors before 0   errors after 8   internal 0
1 call  in flight   errors before 0   errors after 1   internal 0
0 calls             errors before 0   errors after 0   internal 0
                    last error: HTTP request failed for [streamId: 11]
```

After:

```
8 calls in flight   errors before 0   errors after 0   internal 16
1 call  in flight   errors before 0   errors after 0   internal 2
0 calls             errors before 0   errors after 0   internal 0
```

## Measures

Log records at `error` and at `internal` emitted by one transport across an
orderly `close()`, against the number of calls in flight when it happened.

## Control

**The 1-call and 0-call arms.** `8 / 1 / 0` before the fix is what makes it "per
call" rather than "a close logs an error"; the 0-call arm is what says the records
come from the calls and not from `close()` itself.

**`internal 16` after is the other control** — two records per call rather than
zero, so the event is still recorded and the fix moved a level instead of deleting
a log.

## What it establishes, and what it does not

Establishes that an orderly shutdown produced one `error` record per in-flight
call, and now produces none while still recording the event.

Does NOT read what a CONSUMER sees. The status is unchanged either way — it comes
from `_closedDuringCall` by way of `closeAll`, and only the log level moved. The
suite's GUARD covers the inverse case (a real failure with the transport open still
logs at `error`).

Does NOT cover the responder half of this package, which has its own close path.

## Reading

rpc_dart_http — **a count that SCALES, because "each call" is the claim**: `8
calls -> 8 errors`, `1 -> 1`, `0 -> 0`, so one record would have read as a
message rather than a defect, and the 0-call arm says the records come from
the calls and not from `close()`. The error count is read BEFORE the close
too, so the arm asserts its own setup. **`minLevel: internal` is
load-bearing**: with the default the guarded `internal` call is filtered, and
a zero at `error` cannot be told from a log DELETED rather than moved —
`internal 16` after is what distinguishes them. Does not read the consumer
side; the status is unchanged by construction
