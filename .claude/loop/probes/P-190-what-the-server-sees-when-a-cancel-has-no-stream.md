---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b175_phantom_stream.dart
round: 569
commit: 2aaf73d5
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-190 — what does the server see when a cancel has no stream to cancel?

## Why it exists

B-175 asked for "a server-stream call cancelled before its initial metadata goes out; count
streams at the server". Counting streams is right; the setup is not needed. What the defect turns
on is `resetStream` returning false, and the cheapest way to reach that is a call that has already
COMPLETED — its id is released, so nothing is there to reset.

## The harness

A raw `http2.ServerTransportConnection` recording the `:path` of every stream it accepts. That
list is the measurement: a phantom stream is a path the client never asked for.

`answer: false` makes the server accept and never respond, which the third arm needs — see the
control note.

Three arms:

1. a completed unary call, then `resetStream(lastIssuedStreamId)` and, when that returns false,
   the pathless metadata frame core falls back to;
2. a second `sendMetadata` on an id whose stream the server has already ended;
3. a second OPENING frame (with a path) on an id whose stream is still live.

## The numbers (round 569)

Before:

```
ARM 1  resetStream returned false
       paths after the call       [/Svc/Echo]
       paths after the cancel     [/Svc/Echo, /Unknown/Unknown]
ARM 3  activeStreams before       1
       the second frame           accepted
       paths                      [/Svc/Slow, /Svc/Again]
       activeStreams after        1
```

After:

```
ARM 1  paths after the cancel     [/Svc/Echo]
ARM 3  the second frame           RpcStatusException
       paths                      [/Svc/Slow]
       activeStreams after        1
```

## Measures

The server's accepted `:path` list, and `activeStreams` from `health()`. Both, because they
answer different questions: the paths say what went on the wire, and the count says which stream
the transport still believes in — in ARM 3 the count read 1 both before and after while meaning
two different streams.

## Control

**ARM 1 carries its own**: `paths after the call` is read before the cancel, so the
`/Unknown/Unknown` entry is an addition and not the call itself being misreported. And the test's
third case is an ordinary call, which still opens exactly one stream — so the refusals are about
the two cases named rather than metadata having stopped working.

**ARM 2 is the trap this probe exists to document.** A second `sendMetadata` after an ANSWERING
server ended the stream takes the no-methodPath branch, so it reads as fixed and says nothing
about the overwrite. The overwrite is only reachable while the first stream is LIVE, which needs a
server that never answers. An arm that cannot reach the code reads exactly like a clean one
(`L-15`).

## What it establishes, and what it does not

Establishes both halves of B-175: a cancel for an id with no stream opened a request at the
server, and a second opening frame on a live id stranded the first stream while the count still
read 1.

Does NOT establish what the server DOES with the phantom call. It records the path and answers;
whether a real responder spends a handler slot on `/Unknown/Unknown` is not driven here.

Does NOT drive the other two routes to `resetStream == false` the lead names — an id cleared by
reconnect, and one reserved but never opened. Both reach the same early return by construction,
which is not the same as witnessed.

## Reading

rpc_dart_http2 — a raw `ServerTransportConnection` recording the `:path` of
every stream it accepts, which makes a phantom stream a path the client never
asked for: `cancel after a completed call [/Svc/Echo, /Unknown/Unknown] ->
[/Svc/Echo]`, and `a second OPENING frame on a live id [/Svc/Slow, /Svc/Again]
-> [/Svc/Slow]`. **The cheapest route to `resetStream == false` is a COMPLETED
call**, not the server-stream setup the lead asked for. Reads `activeStreams`
beside the paths because in the overwrite arm the count is 1 before and after
while meaning two different streams. Its second arm is kept as documentation
of the trap: a second frame after an ANSWERING server ended the stream takes
the no-methodPath branch and says nothing about the overwrite, which needs a
server that never answers
