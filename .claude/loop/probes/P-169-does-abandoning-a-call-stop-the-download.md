---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b140_abandoned_keeps_reading.dart
round: 536
commit: 4ccf1eb1
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-169 — does abandoning an HTTP/1.1 call stop the download?

## Why it exists

From the client, an abandoned call looks identical whether or not the work stopped: the future is
dropped either way and nothing local reports anything. So the reading has to come from the SERVER,
which is the only side that can say whether the response was still being sent.

## The harness

A bare `HttpServer` that streams forty 1 KiB chunks at 50 ms each, flushing after every one and
recording how many it managed to write and whether it reached the end. The transport is driven
directly — `createStream`, `sendMetadata`, `sendMessage(endStream: true)` — because the question is
about `releaseStreamId`, not about the caller pipeline above it.

The send is deliberately NOT awaited: it completes only when the whole body has been read, which is
the thing being measured.

## The numbers (round 536)

```
  arm                          chunks the SERVER wrote   server finished
  call abandoned at 300ms      40 of 40                  true
  CONTROL not abandoned        40 of 40                  true
```

After the fix the abandoned arm reads `21 of 40 / false`.

## Measures

Chunks the server wrote, and whether it finished. Two readings because "wrote fewer" alone would also
describe a server that crashed.

## Control

**An arm nobody abandons.** Before the fix the two are identical, which is the finding; after it, the
control is what says the transport still completes an ordinary call rather than breaking every request.

## What it establishes, and what it does not

Establishes: `releaseStreamId` freed bookkeeping only. The POST and the body read ran to completion,
so a cancelled or timed-out call held its socket and its bandwidth until the server finished — while
its `maxActiveStreams` slot had already been returned.

Does NOT count sockets. The lead asked for open sockets at the server; "the server finished writing"
is the same fact one step earlier and needs no `lsof`.

Does NOT test the web implementation. `package:http`'s browser client honours `abortTrigger` through
`AbortController`, and nothing here ran on a browser.

Does NOT say what a cancel does to the server's HANDLER. Aborting the request closes the socket; the
handler learns only when it next writes, and this transport still implements no `IRpcStreamReset`.

## Reading

rpc_dart_http — **reads the abandoned side from the OTHER end**, because a
dropped future reports nothing locally whether the work stopped or not: the
server streams a long response and records how far it got and whether it
finished. Two readings, since "wrote fewer" alone also describes a server that
crashed. Its control (a call nobody abandons) is identical BEFORE the fix —
which is the finding — and separates after it, which is what says the
transport still completes ordinary calls.
