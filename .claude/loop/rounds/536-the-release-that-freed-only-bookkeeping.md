---
round: 536
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-14
bench: P-169 — new
commit: yes
severity: S2
---

# Round 536 — the release that freed only bookkeeping

## Target

B-140, next in rank order: an abandoned HTTP/1.1 call keeps its request and body read running.

Lens RPC-14 again, and the third distinct form of it in seven rounds: round 530 found work QUEUED
behind a bounded wait, round 533 found a timeout that could not cancel, and this is a teardown that
frees the accounting and not the work.

## Hypothesis

`releaseStreamId` only removes map entries; `_httpClient.send` and `_readBounded` continue to the end.

## Before

```
  arm                          chunks the SERVER wrote   server finished
  call abandoned at 300ms      40 of 40                  true
  CONTROL not abandoned        40 of 40                  true
```

Bench `../probes/P-169-does-abandoning-a-call-stop-the-download.md`.

CONFIRMED, and the two arms being IDENTICAL is the finding: abandoning changed nothing.

**Read at the server, because the client cannot tell.** An abandoned call drops its future either way
and reports nothing locally, so only the sending side knows whether the response was still going out.

## Mechanism

`releaseStreamId` removed `_pending`, `_activeStreams` and the id. Nothing touched the request. The
`maxActiveStreams` slot is returned at that same moment, so the ceiling stops bounding real sockets
exactly when it matters most — a cancelled call frees its slot and keeps its socket.

## After

```
  call abandoned at 300ms      21 of 40                  false
  CONTROL not abandoned        40 of 40                  true
```

`http.AbortableRequest` with a per-stream trigger, registered before the send and completed by
`releaseStreamId`. `package:http` 1.6 is already the resolved version, so this needed no dependency
change.

## Canary

The `abort.complete()` removed, leaving the map entry and the request shape untouched: the witness
fails `Expected: false / Actual: <true>`. Control and guard pass in that state.

The guard is what keeps the fix from being worse than the defect: **an abandoned call must report
NOTHING.** `RequestAbortedException` is caught on its own branch, above the general handler, because
the abort is this side's own doing — reporting it would answer a stream the endpoint has stopped
listening to, and logging it at error would make ordinary teardown look like breakage.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. rpc_dart_http: 165 passed.

## Not fixed

**`IRpcStreamReset` is still not implemented, and the lead claims one change closes both.** It does
not. Aborting the request closes the socket; the server's HANDLER learns only when it next writes, and
that is a different mechanism from a reset frame core can send. B-97 stopped at the same boundary in
round 488 for the same reason. Whether this transport should advertise the capability changes what core
does on every cancel, which is a design decision rather than a round's.

**No socket count.** The lead asked for open sockets at the server; "the server finished writing" is
the same fact one step earlier and needs no external tool.

**The web client is untested.** `package:http`'s browser client honours `abortTrigger` via
`AbortController`, so the fix should hold there, but nothing ran on a browser and this test is
`@TestOn('vm')` because it needs `HttpServer`.

**21 of 40 is not analysed.** The abandon lands at 300 ms and the chunks are 50 ms apart, so a stop at
6 would be tight; 21 says the abort took roughly a second to take effect. Whether that is
`package:http`, dart:io's socket teardown, or the server's own buffer was not separated.

## Links

Lens RPC-14. Bench P-169 (new). Lead B-140 closed. B-97 is the other half — the reset this does not
implement — and round 488 is where it was deliberately left.
