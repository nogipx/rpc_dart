---
file: packages/transport/rpc_dart_websocket/test/protocol_close_reason_is_bytes_test.dart
round: 392
commit: a82bcf4c
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-81 — does a protocol close survive a non-ASCII reason?

## Why it exists

`closeForProtocolError` trimmed its reason by CHARACTERS against a cap
expressed in BYTES. The reason is peer-controlled — `validateMetadata` quotes
the header name it rejected — so the gap is reachable by anyone.

## Measures

One thing, on a real socket: what the PEER ends up with. The close code it
observes, and the byte length of the reason that arrived.

Lives in `test/` rather than `.dart_tool/probe/` because the witness and the
bench are the same two arms.

## The fixture is the whole design

`'Invalid metadata header name: ${'кириллица' * 6}'` — **84 characters, 138
bytes**, and both numbers are asserted in the test itself:

- `> 123 bytes`, or it would not exceed the cap and there would be nothing to
  see;
- `<= 100 characters`, or the OLD code would have trimmed it anyway and the arm
  would prove nothing about which unit is counted.

A first version used a 140-character string and failed its own second
assertion — the bench caught its own fixture before the round could draw a
conclusion from it.

## Control

The GUARD arm: a short ASCII reason, which must arrive whole and untrimmed. It
stays green on both sides of every canary, so the fix is not credited with
truncating things that fit.

## The numbers (round 392)

```
arm                     before                                after
84 chars / 138 bytes    Invalid argument (reason): must be    close 4400,
                        <= 123 bytes ... then a 5 s timeout,  reason <= 123 bytes
                        the close never happens
short ASCII             delivered whole                       unchanged
```

## What it establishes, and what it does not

Establishes: an oversized close reason used to prevent the close entirely on the
VM, and does not now.

Does NOT witness the fallback (`sink.close(code)` after a throw). Removing it
while keeping the trim leaves both arms green — with the trim in place nothing
on this platform rejects the reason. It is kept for the runtime this test cannot
reach, and that is recorded rather than assumed.

Nor does it cover dart2js, where the owner's report says WHATWG `close()` throws
`SyntaxError` past 123 bytes. `melos run test:web` cannot host a socket server,
so that arm has no bench here.
