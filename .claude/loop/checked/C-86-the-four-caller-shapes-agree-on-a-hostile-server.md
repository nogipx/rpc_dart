---
round: 851
commit: 3d50ca9f
paths: [packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/contracts/caller_trailer.dart]
scope: the four caller shapes over a channel transport against fourteen hostile frame sequences (P-317); not http or http2
---

# C-86 — the four caller shapes agree on a hostile server

Unary, server stream, client stream and bidi end the same hostile response
the same way, the one-response shapes (unary, client) refusing no message
and two messages with INTERNAL where the streaming ones accept zero or more.
Bench `../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`,
the probe extended to all four shapes in round 851.

One row did not agree and this record missed it: `one message + 3 bytes,
OK` read `OK value=a` on unary and INTERNAL on the other three. Round 853
fixed it (`853-a-unary-response-with-trailing-bytes-is-an-error.md`).

## Control

P-317's valid row: OK on all four.
