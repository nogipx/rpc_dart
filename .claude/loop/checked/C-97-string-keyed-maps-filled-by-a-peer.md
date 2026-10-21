---
round: 889
commit: 0d404ad9
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
scope: every Map/Set/HashMap with String keys in rpc_dart lib and the transports' lib, by text sweep; each one read for whether a peer chooses the keys it inserts
---

# C-97 — string keyed maps filled by a peer

After rounds 887 (CBOR map decode) and 888 (rate limiter per-key store), a
text sweep for `(Map|Set|HashMap|LinkedHashMap|HashSet)<String` in core and
transport `lib/` found no third place where a peer inserts keys it chooses
in unbounded number:

- `RpcContext._headers`, `_credentialNames`: built from peer metadata, but
  capped at `maxHeaders` (128) before they get here, so a fully colliding set
  costs about 128^2/2 comparisons per call.
- `GrpcHealthServiceStatus._statuses`: written only by `setStatus` (server
  code). Check and Watch use the peer's service name as a LOOKUP; Watch adds a
  listener to a broadcast stream, not a keyed entry.
- `RpcGrpcCompression._codecs`, websocket `allowedOrigins`/`permittedOrigins`, the
  responder registry, contracts, primitives, log scope/controller/filter/
  redaction: keys chosen by the server or the application; the peer's string
  is at most looked up.

## Control

The same sweep finds both sites fixed in 887 and 888 (`special_cbor.dart`,
`rate_limiter.dart`), so it can see a peer-filled map when one exists.
