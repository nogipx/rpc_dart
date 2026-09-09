---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/reconnect_orphan_rate.dart
round: 241
commit: aaa5806d
paths: [packages/transport/rpc_dart_http2/lib/**]
status: valid
---

# P-19 — how often does a SEQUENTIAL reconnect orphan a connection?

Drives `connect -> reconnect -> reconnect -> close` N times against a real
`RpcHttp2Server`, polling the server's own open/close counters to an 8 s
deadline after each cycle, and reports the rate. `_iterations` at the top is the
knob; 150 takes about 5.5 minutes at ~2.2 s a cycle, so run it in the
background and read the progress lines rather than piping it through `tail`,
which holds everything until EOF.

## Measures

Connections the SERVER still holds 8 seconds after the client closed —
`onConnectionOpened` minus `onConnectionClosed` — plus, per orphaned cycle,
WHICH of the three connections never closed (1 = connect's, 2 and 3 = each
reconnect's), by `identityHashCode` of the socket the server was handed.

That ordinal is the whole value of this bench. Without it the finding is "a
connection sometimes leaks"; with it, it is "the DISCARDED connections leak and
the live one does not", which is a different defect and a different fix.

## Control

Two arms differing only in whether the connect path goes through the test
suite's stalling CONNECT proxy (400 ms) or straight to the server:

```
arm            iterations  orphaned   which connection
stalled proxy  90          0          —
direct         390         5          [1], [2], [2], [2] (two predate the ordinal)
```

The stall is what `concurrent_reconnect_test` uses to widen the race, and it
produces NOTHING here — so this is not the concurrent-overlap defect that test
already pins. The rate is ~1.3% on the direct path, which is why it only ever
appears in a full-suite run.

**Underpowered for verdicts about a FIX.** At 1.3%, 150 iterations expect two
orphans, so "0 in 150" is not evidence. Round 241's candidate fix measured 1 in
150 against 5 in 390 and that difference is noise; see B-25.
