---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b148_what_a_buffered_request_costs.dart
round: 585
commit: 76b07afd
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-205 — what one buffered request body costs

## Why it exists

B-148 asks for "allocation for a 10 MiB request". The number alone says nothing
unless something says what it OUGHT to be, so the probe runs the library's buffer
beside two bare ones that bracket the answer.

```
LIBRARY   sendMetadata + sendMessage(endStream: false), nothing fired
LIST      a bare `List<int>..addAll(same bytes)`
BUILDER   a bare `BytesBuilder(copy: false)..add(same bytes)`
```

No server and no request: `_fireRequest` runs only on `endStream` or
`finishSending`, so what is measured is the BUFFER and not the upload.

## The harness

32 MiB as one `Uint8List`, with `ProcessInfo.currentRss` read three times in the
library arm — before the payload exists, after it exists, and after the buffer has
taken it. The middle reading is what separates the buffer's cost from the
payload's; without it the arm charges the buffer for bytes the caller had already
allocated.

The two bare arms keep their buffer reachable while RSS is read, which is what
printing its length is for.

## The numbers (round 585)

Before:

```
LIBRARY   32 MiB payload   the buffer's own  +205 MiB
LIST      32 MiB payload   +165 MiB
BUILDER   32 MiB payload     +1 MiB
```

After:

```
LIBRARY   32 MiB payload   the buffer's own    +0 MiB
LIST      32 MiB payload   +528 MiB
BUILDER   32 MiB payload     +0 MiB
```

## Measures

Resident bytes added by holding one request body, separated from the payload the
application already allocated.

## Control

**The two bare arms are the control and they bracket the library's.** Before, the
library sits with LIST; after, with BUILDER. That is the whole reading, and it is
why neither bare arm needed to be run in a separate process.

**They are a bracket and NOT a ratio.** LIST read `+165` in one run and `+528` in
the next with identical input — RSS for a growable list depends on the heap's
state and on which pages have been faulted in. Do not quote the bare arms as
numbers; quote which one the library matches.

## What it establishes, and what it does not

Establishes that the caller's buffer cost several times its payload and now costs
nothing beyond it.

Does NOT measure time. The second copy (`Uint8List.fromList` over a 32 MiB list
of boxed-width elements) has a CPU cost that this probe does not read; the lead
filed the memory claim and that is what is answered.

Does NOT measure the multi-chunk path. `takeBytes()` concatenates when there is
more than one chunk, so a client stream of N messages pays one copy at fire time;
the single-chunk case — every unary call — pays none. The suite covers the
multi-chunk correctness.
