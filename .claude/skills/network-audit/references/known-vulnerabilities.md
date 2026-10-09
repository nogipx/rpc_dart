# Known vulnerability classes, with probe recipes

Each entry gives:

- **Mechanism**: how the attack works.
- **Seen in**: public CVEs or audit findings with this shape.
- **Here**: where to look in rpc_dart. Confirm the symbols with dart-runner;
  they move.
- **Probe**, **Pass** and **Control**: a recipe for the evidence loop. Write
  the real probe for the code as it stands, under the package's
  `.dart_tool/probe/`.
- **Journal**: what to pass to `loop.py find` first.

An entry is a question. "This class was fixed once" is a record at an old sha,
not a pass.

Measurement tools that work for every entry: `ProcessInfo.currentRss` sampled
during the attack (take the peak, not the end value); counts of live timers
and subscriptions, taken by wrapping the zone; handler invocation counters;
and a **liveness call**, an ordinary call on a fresh connection after the
attack, with a short deadline.

Contents: WebSocket (WS), codecs and parsers (CD), message passing (MP),
HTTP/1.1 (H1), the RPC layer (R), generic (G), HTTP/2 in brief (H2).

---

## WebSocket (WS)

### KV-WS-01 Decompression bomb through permessage-deflate
- **Mechanism.** The size limit counts compressed bytes, and inflation is
  unbounded or checked only after it finishes. RFC 7692 §6.2 requires a limit
  on the decompressed size.
- **Seen in.** CVE-2026-15709 (libsoup; the size check runs after inflation
  and is off by default for clients), CVE-2026-1526 (undici), CVE-2026-107227
  (AsyncHttpClient; the aggregator ran before the inflater), CVE-2026-39804
  (Bandit), ratchet issue #67.
- **Here.** Compression is off by default (`CompressionOptions.compressionOff`
  in `websocket_io_connections.dart` and `websocket_bounded_upgrade.dart`). The
  caller has an opt-in (`enableCompression` in `ws_open_io.dart`). The dart:io
  inflater sits below every rpc_dart limit (RPC-18).
- **Probe.** Enable compression on both ends. The peer sends one message of
  zeros that compresses roughly 1000:1, sized so the inflated message is far
  above `maxMessageLengthBytes`. Measure peak RSS. Run it in **both**
  directions: hostile client against server, and hostile server against
  caller.
- **Pass.** Refused, with peak RSS bounded by a small multiple of the limit;
  the liveness call succeeds.
- **Control.** The same payload with compression off. And the same inflated
  size sent uncompressed, which isolates the inflater.
- **Journal.** `find 'permessage-deflate'`, lens RPC-17, RPC-18.

### KV-WS-02 Whole-message assembly before the size limit
- **Mechanism.** The WebSocket layer reassembles a full message (all
  fragments) before handing it up, so a limit on the RPC frame fires after the
  bytes are already resident.
- **Seen in.** The general RFC 6455 §10.4 requirement; frame-size options in
  ws, Netty and tungstenite.
- **Here.** dart:io `WebSocket` delivers whole messages. Look for what bounds a
  single message before rpc_dart's parser sees it.
- **Probe.** The peer sends one message 100x the limit, fragmented into 64 KiB
  frames and dribbled slowly. Sample RSS while it is in flight.
- **Pass.** The connection closes before resident bytes greatly exceed the
  limit.
- **Control.** A message just under the limit.
- **Journal.** `find 'whole message'`, `find --path
  packages/transport/rpc_dart_websocket/lib`, RPC-17.

### KV-WS-03 Fragment and control-frame floods
- **Mechanism.** A fragmented message that never ends; thousands of
  zero-length continuation frames; pings (payload up to 125 bytes) sent faster
  than pongs drain. Each forces work or buffering per frame.
- **Seen in.** The Autobahn suite's sections 5 (fragmentation) and 2 (pings);
  the HTTP/2 analogue is CVE-2019-9512 (ping flood).
- **Probe.** A raw socket after a valid upgrade. Send each pattern for 10
  seconds, and count the bytes the server writes back.
- **Pass.** Bounded memory, bounded write queue, and no per-frame log line
  (B-124's shape). The connection is closed or the frames are ignored.
- **Control.** The same frame rate of ordinary data messages.
- **Journal.** `find 'ping flood'`, C-03.

### KV-WS-04 Cross-site WebSocket hijacking (CSWSH)
- **Mechanism.** Browsers do not apply the same-origin policy to WebSocket.
  A hostile page opens a socket to the server, and the browser attaches the
  user's cookies. Checking `Origin` at the handshake is the only
  protocol-level defence.
- **Here.** `allowedOrigins` and `allowUpgrade` in `websocket_io_connections.dart`.
  A request with no `Origin` is allowed by design (non-browser clients); more
  than one `Origin` header is refused.
- **Probe.** Handshakes with `Origin: https://evil.example`, with the origin
  in mixed case, with a trailing dot or a port, with `null`, and with two
  `Origin` headers. Run each with and without `allowedOrigins` set.
- **Pass.** Refused whenever an allow-list is set, and the docs say plainly
  that cookie auth without an allow-list is open.
- **Control.** The allowed origin itself.
- **Journal.** `find 'allowedOrigins'`, `find 'origin'`.

### KV-WS-05 Handshake resource exhaustion
- **Mechanism.** Work done for an unauthenticated upgrade: header parsing
  without a count limit, a slowloris dribble of the request line, an endpoint
  built per TCP connection before the handshake finishes.
- **Seen in.** ws CVE-2024-37890 (a request with very many headers crashed the
  server); CVE-2023-4785 (gRPC C-core did not handle fd exhaustion on accept).
- **Probe.** (a) A handshake with 10,000 headers. (b) 1 byte per second for
  the whole request. (c) 5,000 TCP connections that never send anything.
  (d) Run past the fd limit (`ulimit -n 256`), then try an ordinary
  connection.
- **Pass.** Each one is bounded by a timeout or a count. Once the fds free up,
  the accept loop recovers instead of dying.
- **Control.** The same number of well-behaved, completed handshakes.
- **Journal.** `find 'TCP SYN'` (B-27), `find 'bounded upgrade'`, RPC-22,
  RPC-28.

### KV-WS-06 A half-open socket and a close handshake that never ends
- **Mechanism.** The peer stops reading, or vanishes without a FIN, or never
  answers a Close frame. Every resource tied to the connection stays held.
- **Probe.** Through toxiproxy, use `timeout` (black-hole) and
  `reset_peer`, mid-stream and mid-close.
- **Pass.** The heartbeat or idle timeout ends it. All streams on the
  connection end with UNAVAILABLE. Their timers and subscriptions are
  released.
- **Control.** A clean close.
- **Journal.** `find 'heartbeat'`, `find 'half-open'`.

### KV-WS-07 Head-of-line blocking among many RPC streams on one socket
- **Mechanism.** One slow consumer on a multiplexed socket stalls every other
  stream, or the transport buffers without bound to avoid stalling.
- **Probe.** Two streams on one connection. One consumer pauses, and the
  producer keeps sending. Measure the other stream's latency and the RSS.
- **Pass.** Per-stream credit bounds the paused stream's buffer, and the
  other stream keeps flowing.
- **Control.** Both consumers active.
- **Journal.** C-07, `find 'read backpressure'` (B-138), RPC-01.

### KV-WS-08 Text and binary frame confusion, invalid UTF-8
- **Mechanism.** A text frame where binary is expected, or invalid or
  overlong UTF-8 in a text frame or a close reason.
- **Probe.** The Autobahn suite, sections 6 and 7.
- **Pass.** A protocol close (1002 or 1007) and a typed error. Never an
  uncaught exception.

### KV-WS-09 Reconnect semantics
- **Mechanism.** Stream ids restart after a reconnect, so a late frame for an
  old call lands on a new one. In-flight calls are silently replayed, or
  silently lost.
- **Journal.** RPC-03, RPC-19, C-11, `find 'reconnect window'`.

---

## Codecs and parsers (CD)

### KV-CD-01 Nesting depth: stack exhaustion
- **Mechanism.** A recursive decoder fed 10^5 nested arrays or maps.
- **Seen in.** CVE-2024-7254 (protobuf-java, nested groups).
- **Here.** `special_cbor.dart` has `_maxDepth` and `_checkDepth`. Check
  every recursive path, not just maps and arrays: tags, indefinite-length
  items nested in each other, and any user codec.
- **Probe.** Generate depth `_maxDepth + 1` and 10^6, for every container
  kind and every tag.
- **Pass.** `FormatException` at the limit, never `StackOverflowError`.
- **Control.** A depth just under the limit decodes.

### KV-CD-02 Allocation by declared length
- **Mechanism.** A length prefix of 2^32-1 (or a negative one) makes the
  decoder allocate before any bytes arrive.
- **Probe.** For every length field (frame header, CBOR byte string, array
  count, gRPC 5-byte prefix): send the maximum declared value with 10 bytes of
  body. Sample RSS.
- **Pass.** Refused before allocating. The limit is checked against the
  declared length.
- **Journal.** C-02, `find 'declared length'`.

### KV-CD-03 Quadratic reassembly
- **Mechanism.** A message delivered in many small chunks is reassembled by
  repeated concatenation, so CPU is O(n²).
- **Probe.** One message at the size limit, in 1-byte chunks (toxiproxy
  `slicer`). Time it against the same message delivered in one chunk.
- **Pass.** Time grows linearly with chunk count.
- **Journal.** B-105.

### KV-CD-04 Decompression bomb at the message level
- **Mechanism.** gzip inside a gRPC message (`grpc-encoding`). The ISIZE
  field lies, or the stream inflates far past the limit.
- **Here.** `parser.dart` and `compression_gzip_io.dart` check the
  decompressed size. The web path differs (B-29).
- **Probe.** As in KV-WS-01, but at the message level, on VM **and** dart2js.
- **Journal.** C-17, B-29, `find 'ISIZE'`.

### KV-CD-05 Integer edges, especially on the web
- **Mechanism.** On dart2js, values past 2^53 lose precision, and 64-bit CBOR
  integers and lengths decode inexactly. Counters wrap.
- **Probe.** CBOR uint64 at 2^53+1 and 2^64-1, plus lengths and ids near
  2^31 and 2^32, on VM and node.
- **Pass.** Either exact, or refused. Never silently different.
- **Journal.** RPC-07, `find '2^53'`.

### KV-CD-06 Hash flooding through peer-chosen map keys
- **Mechanism.** Many keys with colliding hashes turn `Map` inserts into
  O(n²). Dart's `String.hashCode` is not seeded per process.
- **Probe.** Generate colliding strings for the VM's string hash, and decode a
  CBOR map with N of them. Compare the time against N random keys.
- **Pass.** Time scales roughly linearly, or the key count is bounded first.
- **Note.** A hypothesis: measure before filing.

### KV-CD-07 The wrong exception type escapes a decoder
- **Mechanism.** A `RangeError`, `TypeError` or `StateError` thrown from
  decoding peer bytes is mapped to INTERNAL, crashes a listener, or reaches
  the zone.
- **Probe.** The fuzz oracle in methods.md §4. Extend
  `test/fuzz/peer_bytes_decoders_fuzz_test.dart`.
- **Journal.** P-225, round 640, RPC-13.

### KV-CD-08 Type confusion from tags or schemaless decoding
- **Mechanism.** The decoder builds whatever types the peer names (CBOR
  tags, dynamic maps), and the handler then casts them without a check.
- **Probe.** Send a valid frame whose payload has the right shape but the
  wrong types (a string where an int is expected, a map in place of a list,
  unknown tags).
- **Pass.** INVALID_ARGUMENT, or a codec error. Not INTERNAL with a
  `TypeError` message sent back to the peer.

---

## Message passing: isolate, web worker, wasm (MP)

The guest is semi-trusted. Validate what it sends as if it came from a
network peer: it may run third-party code, and a bug on its side must not
take down the host.

### KV-MP-01 The window before the first listener
- RPC-20. Messages sent before the receiving side subscribes are dropped, or
  buffered without bound. Probe a burst at startup.
- **Journal.** RPC-20, B-165, B-173.

### KV-MP-02 Unsendable or throwing payloads
- `SendPort.send` throws on unsendable objects, and `postMessage` on
  unclonable ones. Check that the error becomes a call failure, not a dead
  channel or a zone error.
- **Journal.** `find 'unsendable'`.

### KV-MP-03 Peer death goes unnoticed
- An isolate exits, a worker errors, or the wasm sandbox dies while idle. The
  calls in flight must fail with UNAVAILABLE, and the next call must not
  hang.
- **Probe.** Kill the peer while idle, while mid-stream, and while a call is
  starting.
- **Journal.** B-102, B-161, `find 'onExit'`.

### KV-MP-04 Zero-copy with no backpressure
- A transferable-buffer path that skips credit accounting, so a fast producer
  fills the receiver.
- **Journal.** B-106, B-156.

### KV-MP-05 Payload aliasing
- In-memory transports that pass object references. The sender mutates the
  message after send, and the receiver sees the change.
- **Journal.** B-174.

### KV-MP-06 Native bridge ordering and framing (wasm)
- Large frames reordered or split across a native bridge (Swift and Kotlin
  are separate code). Run it on both platforms.
- **Journal.** B-101, RPC-06, C-57.

---

## HTTP/1.1, the `rpc_dart_http` transport (H1)

### KV-H1-01 Body read before the size limit
- The request body is collected in full (`List<int>` or `toBytes`) before
  the limit is checked. Probe with `Content-Length: 2^40`, with chunked
  encoding and no end, and with a slow body.
- **Journal.** RPC-17, B-148, B-150, C-31.

### KV-H1-02 CORS misconfiguration
- An `Origin` reflected while `Allow-Credentials: true`; `*` together with
  credentials; the policy changed after construction.
- **Journal.** B-153, round 671.

### KV-H1-03 Header injection and repeated headers
- CR/LF or other control characters from metadata reaching a response header;
  repeated headers merged or split differently from the client.
- **Journal.** B-144, B-145, RPC-02.

### KV-H1-04 Credentials forwarded on redirect
- **Seen in.** CVE-2022-0451. dart:io `HttpClient` before Dart 2.16 forwarded
  `Authorization` and `Cookie` on a cross-origin redirect.
- **Check.** The SDK floor in every pubspec, and whether the caller follows
  redirects at all. An RPC caller has no reason to follow one; refusing is the
  safe default.

### KV-H1-05 An abandoned call keeps working
- The client cancels, and the server keeps reading the body or running the
  handler.
- **Journal.** B-140, RPC-14.

---

## The RPC layer, transport-agnostic (R)

### KV-R-01 Work before authentication or method resolution
- Allocation, handler dispatch, logging or a timer started before the request
  is accepted (RPC-22). List everything that happens between "first frame"
  and "method resolved and authorized".

### KV-R-02 Metadata limits, in both directions
- Count, name length, value length and total bytes, on inbound **and**
  outbound (an outbound refusal must pass its own rule: RPC-02). Probe one
  header of exactly the limit, the limit+1, and 10,000 tiny headers.
- **Here.** `RpcSecurityPolicy.maxMetadataBytes`, `maxHeaders`,
  `maxHeaderNameBytes`, `maxHeaderValueBytes`.
- **Seen in.** CVE-2023-32731 (gRPC). The error path for "header too large"
  skipped the rest of the frame's state updates, and the HPACK tables
  desynchronized. **The general shape: a refusal path that leaves shared
  state half-updated.** Check every refusal for state it skips.

### KV-R-03 Method path abuse
- Over-long paths, characters outside the allowed tokens, dotted keys that
  collide (B-113), and an unknown method sent in a loop (what does each
  refusal cost?).
- **Here.** `parseRpcMethodPath`, `kDefaultMaxMethodPathLength`,
  `maxMethodPathLength`.

### KV-R-04 Stream and concurrency limits: charge point and unit
- Where the stream counter is incremented and decremented, and on which
  exits (RPC-05). Whether the cap counts the right unit (RPC-27). Per
  connection versus per process (C-29).
- **Here.** `maxActiveStreams`, `maxConcurrentHandlers`,
  `maxBufferedMessagesPerStream`, `maxBufferedBytes`.

### KV-R-05 Peer-chosen stream ids
- Reused ids, ids never opened, ids at the wrap point, ids of closed streams.
- **Journal.** C-04, C-10, C-53, P-228.

### KV-R-06 Open-and-cancel storms (Rapid Reset, transport-agnostic)
- **Mechanism.** CVE-2023-44487 shape: open a stream, cancel it at once,
  repeat. The server pays to dispatch every one, while the concurrency limit
  never trips, because each stream is already gone.
- **Probe.** Run it on every multiplexed transport, not only HTTP/2. Count
  handler invocations and CPU per opened stream.
- **Pass.** Cancelled-before-dispatch streams start no handler, and the rate
  is bounded.
- **Journal.** C-32.

### KV-R-07 Peer-supplied deadlines
- `grpc-timeout` of `0n`, of `99999999H`, malformed, or negative. A huge
  value must not create a timer that overflows (`long_timer.dart`). A tiny
  one must not let a handler run unbounded. A deadline set by middleware must
  be enforced too (B-244).
- **Here.** `RpcMetadata.parseGrpcTimeout`, `encodeGrpcTimeout`.

### KV-R-08 Half-open streams and slow readers
- A client never half-closes, or never reads its responses. Slots and
  buffers are held for as long as the peer likes.
- **Here.** `halfOpenStreamTimeout`, and the flow-control window fields.
- **Journal.** C-19, C-20.

### KV-R-09 Error and status leakage
- Exception messages, stack traces or internal paths returned to the peer in
  `grpc-message` or status details; secrets in logs. Wrong retryability
  (INTERNAL versus UNAVAILABLE versus RESOURCE_EXHAUSTED) makes clients
  hammer, or give up.
- **Probe.** A handler that throws an error whose message holds a fake
  secret. Read what reaches the client and what is logged.

### KV-R-10 Peer-triggered log amplification
- A warning or error logged on every frame for something the peer controls.
  The project rule: it fires once, behind a bool. Also check for
  interpolation of peer strings into log lines (control characters).
- **Journal.** B-124, `test/transports/flow_controller_logging_test.dart`.

### KV-R-11 Errors that reach the zone
- A peer-triggered path whose future or stream error has no handler. In a
  server this can end the process.
- **Journal.** RPC-13, C-65.

### KV-R-12 Per-call leaks
- Cancellation-token listeners, timers and subscriptions created per call
  and not released on every ending (normal, cancel, deadline, error,
  disconnect).
- **Journal.** B-109, C-37, C-41, U-20.

### KV-R-13 Identity taken from the payload
- **Seen in.** Cortex 2026: a handler trusted a tenant id in the message body
  over the authenticated context. See methods.md §14. Check the framework's
  docs and examples: they should teach reading identity from the
  authenticated context only.

---

## Generic (G)

### KV-G-01 TLS
- `badCertificateCallback` returning `true` anywhere outside tests; a
  hostname that is not verified; the ALPN result not checked; TLS through a
  proxy that downgrades.
- **Journal.** `find 'ALPN'`, round 692, round 698.

### KV-G-02 Dependency CVEs
- `osv-scanner --lockfile=pubspec.lock` at the root, plus the wasm package's
  own lockfile, since it resolves standalone.

### KV-G-03 Accept-loop resilience
- fd exhaustion, an `accept` error, or a TLS handshake error must not end the
  server's listen loop (CVE-2023-4785 shape).

### KV-G-04 Timeouts nobody chose
- A constant inside a dependency (60 s and the like) that bounds, or fails to
  bound, a stage of the connection.
- **Journal.** B-107, RPC-28.

---

## HTTP/2 in brief (H2): low priority

`rpc_dart_http2` rests on `package:http2`, so most of these are the
dependency's to get right and ours to bound (RPC-18). One line each:

- **Rapid Reset**, CVE-2023-44487: HEADERS then RST_STREAM in a loop.
  Covered as KV-R-06 (C-32).
- **CONTINUATION flood**, 2024 (CVE-2024-27316 httpd, CVE-2024-27983 node):
  endless CONTINUATION frames with no END_HEADERS, buffered without bound.
  Journal: `find 'CONTINUATION'`.
- **HPACK bomb**: a small encoded header block that expands to a huge one
  through the dynamic table.
- **HPACK desync on a refusal**, CVE-2023-32731: see KV-R-02.
- **The 2019 set**, CVE-2019-9511 to 9518: data dribble (9511), ping flood
  (9512), resource loop over priorities (9513), reset flood (9514), settings
  flood (9515), 0-length headers leak (9516), internal data buffering (9517),
  empty frames flood (9518).
- **Keepalive abuse**: client pings faster than the server's policy allows.
  The answer is GOAWAY `ENHANCE_YOUR_CALM`.
- **Conformance**: h2spec.

---

## Sources

- RFC 6455 §10.4, RFC 7692 §6.2
- https://access.redhat.com/security/cve/cve-2026-15709
- https://github.com/advisories/GHSA-vrm6-8vpv-qv8q
- https://advisories.gitlab.com/maven/org.asynchttpclient/async-http-client/CVE-2026-107227/
- https://cna.erlef.org/cves/CVE-2026-39804.html
- https://github.com/graphform/ratchet/issues/67
- https://github.com/dart-lang/sdk/security/advisories/GHSA-c8mh-jj22-xg5h (CVE-2022-0451)
- https://security-tracker.debian.org/tracker/CVE-2023-32731
- https://access.redhat.com/security/cve/cve-2023-4785
- https://ostif.org/wp-content/uploads/2026/07/26-04-2696-REP-Cortex-security-audit-V1.1.pdf
- https://grpc.github.io/grpc/core/md_doc_security_audit.html
- https://github.com/crossbario/autobahn-testsuite
