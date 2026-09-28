---
status: closed (round 484)
round: 347
commit: e78bd8e2
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/terminate_rejects_into_the_zone.dart
reason: "no reachable user-visible failure was established — the transport's own close path does not reach the state, measured — and every fix for it is a design decision about zone-guarding a dependency's internal throws"
---

# B-35 — package:http2's finish() throws into the zone, and no call site can catch it

## CLOSED by the owner (round 484) — the report stays written, unposted

*"Close them so they stop getting in the way."* Posting was the only remaining
step and the owner has declined to take it.

**Nothing is lost by this.** The bug is in a dependency, and it is measured that
this library never reaches it: `close()` RSTs every stream before calling
`finish()`, and the trigger is a connection that NEVER OPENED a stream, which
rpc_dart does not produce. The characterisation test stays in place and is what
would notice if the dependency's behaviour changed.

The report below is complete, verified against http2 3.1.0 (latest), checked for
duplicates, and runnable — `upstream_minimal.dart`. If it is ever wanted, it can
be pasted as it stands; re-run the repro first, since time will have passed.

## Round 480 — the report is WRITTEN AND VERIFIED. Posting it is the owner's.

The decision's remaining work was "file the upstream issue". Everything up to
the POST is done: filing it is outward-facing and the owner's name goes on it.

**The status stays `decided by owner`, on B-38's precedent** — that lead waits on
the owner booting a simulator, this one on the owner pasting an issue, and
neither is a judgement a round can make. So both keep showing up under "owner
decisions not yet carried out", which reads as unfinished and is: what remains is
one action each, named exactly, with nothing else to do first.

Round 480 rebuilt the reproduction with **`package:http2` on both ends and no
rpc_dart at all** — a maintainer cannot be asked to install this library to see
their own bug — and it sharpened the finding twice.

**The trigger is narrower than this record said.** It is not teardown in
general; it is `finish()` on a connection that never opened a stream. The arms
with traffic on them are silent:

```
finish(), no streams ever opened     UNCAUGHT IN ZONE  (5 of 5 runs)
finish() after a completed stream    silent
finish() then terminate()            silent
CONTROL: terminate() alone           silent
CONTROL: neither called              silent
```

**And `finish()` does not merely complete before the throw — it completes
NORMALLY, printing after it.** The wording above ("thrown after finish()'s own
future has completed") described the rpc_dart-mediated ordering. The invariant
that actually holds, and the one the report makes, is that the error never
reaches the returned future at all, whatever the ordering.

Verified on **http2 3.1.0, which `dart pub outdated` reports as the LATEST**, so
it is not already fixed upstream.

`../probes/P-122-a-goaway-written-after-the-sink-closed.md`,
`../rounds/480-the-report-that-had-to-run-without-us.md`.

### Checked for a duplicate before posting (round 483)

Round 480 established the bug is not FIXED upstream. It did not check whether it
was already REPORTED, which is the other way a report wastes a maintainer's time.

`dart-lang/http` (the monorepo `package:http2` now lives in), all 12 open
`package:http2` issues plus a full-text search for the error string:

```
#1597  "Bad state: Cannot add event after closing"   package:web_socket_channel,
                                                      closed 2019 — different package
#1364  "Can't catch exception occur during goaway"   about StreamException not
                                                      being EXPORTED; an API
                                                      surface complaint, not this
#1380  "How to catch the exception thrown by         same FAMILY, different error
        ClientTransportConnection.terminate?"         and different call
```

**Not a duplicate. The report stands.**

**#1380 is worth linking but NOT claiming.** It is the same family — a teardown
error that neither `try/catch` nor `.catchError` can hold — open and unanswered
since June 2023 with no reproduction. Its error is
`TransportConnectionException` "Connection is being forcefully terminated",
from `terminate()`, not ours. Every arm in P-122 terminated with the stream
already ENDED, so none of them could speak to it; round 483 added its shape
(`makeRequest`, `sendData`, no `endStream`, then an awaited `terminate()`) and
it is **silent** on 3.1.0, with nothing caught at the call site either.

So it did not reproduce and may well have been fixed since 2023. Mention it as
related; do not assert that this report explains it.

### The issue text, ready to post

Reproduction lives at
`packages/transport/rpc_dart_http2/.dart_tool/probe/upstream_minimal.dart` so it
is a file that RUNS rather than a quotation that rots. Re-run it before posting
if any time has passed.

> **Title:** `finish()` writes a GOAWAY after closing its own sink, throwing an
> uncatchable `StateError` into the zone
>
> **Version:** http2 3.1.0 (latest), Dart 3.10.1, macOS.
>
> Calling `finish()` on a `ClientTransportConnection` that has never opened a
> stream throws `StateError: Bad state: Cannot add event after closing`. The
> throw happens inside a `StreamSubscription` callback with no `onError`, so it
> reaches the enclosing zone — **`finish()`'s own future completes normally and
> never sees it**, which means no `await`, `.catchError` or `try/catch` at the
> call site can handle it. Only `runZonedGuarded` around the whole connection
> contains it, and that reroutes every other async error too.
>
> It is deterministic: 5 of 5 runs. Opening and completing one stream first
> makes it go away, as does `terminate()` on its own.
>
> Trace:
>
> ```
> #1  BufferedBytesWriter.add (package:http2/src/async_utils/async_utils.dart:108:24)
> #2  FrameWriter._writeData (package:http2/src/frames/frame_writer.dart:309:16)
> #3  FrameWriter.writeGoawayFrame (package:http2/src/frames/frame_writer.dart:288:5)
> #4  ConnectionMessageQueueOut._trySendMessage (package:http2/src/flowcontrol/connection_queues.dart:163:20)
> #5  ConnectionMessageQueueOut._trySendMessages (package:http2/src/flowcontrol/connection_queues.dart:92:9)
> #6  new ConnectionMessageQueueOut.<anonymous closure> (package:http2/src/flowcontrol/connection_queues.dart:46:7)
> #14 BufferIndicator.markUnBuffered (package:http2/src/async_utils/async_utils.dart:29:19)
> #28 Connection._setupConnection.<anonymous closure> (package:http2/src/connection.dart:189:42)
> ```
>
> Reading it bottom-up, the termination path emits the event that drives the
> queue that writes to the sink termination just closed:
>
> 1. `finish()` enqueues a GOAWAY and, with no streams to drain, closes the frame
>    writer's sink.
> 2. `_frameWriter.doneFuture.whenComplete(...)` (`connection.dart:189`) fires
>    `_terminate(...)`.
> 3. That runs `BufferIndicator.markUnBuffered` (`async_utils.dart:29`), emitting
>    a `bufferEmptyEvents` event.
> 4. The listener registered in `ConnectionMessageQueueOut`'s constructor
>    (`connection_queues.dart:45-47`) calls `_trySendMessages`.
> 5. `_trySendMessages` guards on `!wasTerminated` alone
>    (`connection_queues.dart:80`). Termination is still in progress here, so the
>    guard passes.
> 6. The GOAWAY is dequeued and written to a sink that is already closed.
>
> So the queue can be driven after its writer's sink has closed, because the
> event driving it is emitted by the close path itself and the only guard is one
> that has not been set yet. A guard on the writer's closed state at
> `_trySendMessages`, or clearing `_messages` when the writer closes, would both
> cover it — but which is right is yours to say.
>
> Possibly related, though I could not reproduce it on 3.1.0: #1380 reports a
> teardown error from `terminate()` that no call site can catch. Same family,
> different error and different call — driving its shape (a request in flight,
> then an awaited `terminate()`) is silent here.
>
> Minimal reproduction (`dart pub add http2`, then run):
>
> ```dart
> import 'dart:async';
> import 'dart:io';
>
> import 'package:http2/http2.dart';
>
> Future<void> main() async {
>   final server = await ServerSocket.bind('127.0.0.1', 0);
>   server.listen((socket) {
>     ServerTransportConnection.viaSocket(socket)
>         .incomingStreams
>         .listen((_) {}, onError: (Object _) {});
>   }, onError: (Object _) {});
>
>   runZonedGuarded(() async {
>     final socket = await Socket.connect('127.0.0.1', server.port);
>     final connection = ClientTransportConnection.viaSocket(socket);
>
>     await connection.finish();               // completes normally
>     print('finish() completed normally');
>
>     await Future<void>.delayed(const Duration(milliseconds: 500));
>     print('no error was observable at the call site');
>   }, (error, stack) {
>     print('UNCAUGHT: $error');
>   });
>
>   await Future<void>.delayed(const Duration(seconds: 1));
>   await server.close();
>   exit(0);
> }
> ```

## Measured

```
unawaited(conn.terminate()) after finish()        StateError in the zone
conn.terminate().catchError(...) after finish()   StateError in the zone
conn.finish() and NOTHING else                    StateError in the zone
```

`StateError: Bad state: Cannot add event after closing`, thrown **after**
`finish()`'s own future has completed. It is not a rejection: a `.catchError` on
the returned future does not see it, which is what the second row shows.

Three states that do NOT throw, so it is specific rather than ambient:
terminate() on a live connection, terminate() twice, terminate() after the
socket was destroyed.

## Why it is a lead and not an incident

The transport's own `close()` does not reach it. Measured over a real
connect / unary call / `close()` / `close()` again, inside `runZonedGuarded`:
nothing escapes. `close()` RSTs every stream before calling `finish()`, so
finish() has nothing to drain and returns promptly — rounds 346 and 347 failed
to make it time out even with the budget forced to 1 ms and to zero.

So the hazard is real and the path to it from this library is not established.

## What the code already says

`rpc_http2_caller_transport.dart`, above the close path:

> terminate() ... is the right primitive on a dead connection anyway --
> finish() on one throws from package:http2 into the root zone.

Correct, and round 347 still misread it — see the round record. The `try/catch`
around `await _connection.finish().timeout(...)` is right for what it CAN catch;
the zone throw is out of reach of any handler at the call site.

## What a fix would have to decide

Only a zone contains it. Running the connection inside `runZonedGuarded` changes
where a genuine transport error surfaces for the application, which is a
behaviour decision rather than a repair — and it would swallow errors this
library currently lets through on purpose. The alternative is upstream: report it
to package:http2.

Do NOT "fix" it at the call site. Two attempts measured, both ineffective: a
`try/catch` around `unawaited(...)` (the shipped form — it can only see a
synchronous throw) and `.catchError` on `terminate()` (terminate is not the
source).

## The three options, as they stood

None of them is a repair:

1. leave it — nothing in this library reaches the state, measured;
2. run the connection in `runZonedGuarded`, which contains it and also changes
   where genuine transport errors surface for the application;
3. report it upstream to `package:http2` and leave the comment as the record.

Round 347 recommends (1) plus the characterisation test that is already in, and
(3) if the owner wants it off the list permanently.

## Superseded decision (round 415) — taken jointly with B-39

**Zone-guard the connection's construction, and ROUTE what the zone catches.**
The full statement of it lives in
[B-39](B-39-websocket-send-throws-into-the-root-zone.md); the two were decided
together because it is one mechanism and one trade.

Here it meant guarding where `RpcHttp2CallerTransport` builds its
`ClientTransportConnection`, so a `finish()` that throws AFTER its own future
completed lands somewhere that can report it instead of in the root zone.

**This lead keeps its own qualifier, and it is the reason it stayed a lead:**
nothing has yet produced a user-visible failure through `close()`. Measured over
connect / call / close / close-again inside `runZonedGuarded`, nothing escapes —
`close()` RSTs every stream before calling `finish()`, and rounds 346-347 could
not make it time out even with the budget forced to 1 ms and to zero.

So the round carrying this is fixing a reachable-in-principle throw, not a
reproduced failure. It must say so in its verdict rather than claiming a fix it
cannot witness end to end, and the characterisation test stays as what it
already is: the thing that closes this lead the day the dependency stops.

## Guarded by

`packages/transport/rpc_dart_http2/test/finish_throws_into_the_zone_test.dart` —
asserts the dependency still behaves this way, so the day it stops, this lead
closes.

## Owner decision

Taken after round 426, and it SUPERSEDES the joint one above.

**Leave it. Report upstream to `package:http2`. No behaviour change here.**

The joint decision above is withdrawn **for this lead only** — B-39 keeps its
construction guard unchanged, so the two are no longer one decision. Asked
directly with three options on the table, and the reasoning that decided it is
the qualifier the joint decision itself wrote down: nothing in this library
reaches the state. Measured over connect / call / close / close-again inside
`runZonedGuarded`, with the finish budget forced to 1 ms and to zero, nothing
escapes.

So the round that would have carried the guard was, by its own admission, fixing
a reachable-in-principle throw with no reproduced failure — and paying for it
with the trade the guard costs: every async error from that connection rerouted,
not only this one.

**What stays:** the characterisation test below, which is what closes this lead
the day the dependency stops throwing. **What a future round may do:** file the
upstream issue; that is the only work this lead now has.

**Do not re-derive the guard as new.** It was proposed, decided, and withdrawn
with a reason. A round that finds a REACHABLE path from this library to the
throw has a new fact and should re-open the question with it — that, and nothing
less, is what would change this.
