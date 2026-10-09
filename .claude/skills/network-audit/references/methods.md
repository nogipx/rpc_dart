# Audit methods

These are the methods published audits of network and RPC libraries use. The
sources are Cure53 on gRPC; Ada Logics on CRI-O, Dapr and Istio; Trail of Bits
on Dragonfly; Quarkslab on Cortex; and the CNCF fuzzing audits. Each section
gives the method, why it finds bugs, and how to apply it here.

Contents:
1. Threat model
2. Attack-surface map
3. Per-unit resource accounting
4. Fuzzing
5. Conformance suites
6. Differential testing against a reference implementation
7. Fault injection and network chaos
8. Lifecycle and state-machine driving
9. Soak and leak accounting
10. Dependency audit
11. Defaults and parity review
12. Cross-runtime review (dart2js, Wasm)
13. Code-review hotspots
14. Identity and trust review

## 1. Threat model

Name the peers before the bugs. Each one is trusted to a different degree.

| Peer | Trust | Typical channel |
| --- | --- | --- |
| Remote client, before auth | none | WebSocket upgrade, HTTP/1.1 request, HTTP/2 preface |
| Remote client, after auth | identity is known, intent is not | any call |
| Remote server, seen from a caller | none: a malicious or compromised server | every caller transport |
| Isolate, web worker, wasm guest | semi-trusted: same app, but may run third-party code | message passing |
| Local user code (handlers, interceptors) | trusted, but buggy | in-process |

The caller side is part of the attack surface too. The 2026 permessage-deflate
CVEs (libsoup, undici, AsyncHttpClient) all hit clients receiving data from a
hostile server. Audit caller transports with the same catalog as responders.

The assets to protect, in order: availability of the process, availability of
other calls on the same connection, memory, correctness of results,
confidentiality of metadata and logs.

## 2. Attack-surface map

For every entry point, record:

- who can reach it (the threat-model row);
- what is allocated or started **before** authentication, method resolution
  and limit checks: buffers, endpoints, timers, isolates, log records;
- which limits apply, and where each one is checked relative to the allocation.

Output: the entry-point table in SKILL.md. The column "resident before any
limit" holds most findings: a limit that fires only after the bytes are
already held (lens RPC-17), or a dependency that buffers below every limit you
own (RPC-18).

## 3. Per-unit resource accounting

A limit bounds one unit. The attack uses another. For each limit, list every
unit the peer controls and ask whether something bounds it:

- **bytes**: on the wire, after decompression, after decoding to objects (a
  decoded `Map` weighs far more than its CBOR);
- **counts**: messages, streams, headers, frames, fragments, ids;
- **time**: how long a slot is held (half-open streams, slow readers, dribbled
  handshakes);
- **work**: handler invocations, decode CPU, log records, timers created;
- **persistence**: what remains after the peer disconnects.

Compute the **amplification ratio**: resident bytes, or work, divided by peer
bytes. Anything above a small constant needs a reason. A cap counted in items,
where one item's weight is chosen by the peer, is a finding shape of its own
(RPC-27).

## 4. Fuzzing

Most audit findings come from fuzzers, and the strongest ones are stateful.
CRI-O's audit used a 900-line fuzzer that started a real gRPC server and sent
it sequences of random messages. Dapr's 39 fuzzers found three issues, two of
them inside third-party libraries.

Three levels, cheapest first:

1. **Byte-level, decoders.** Random and mutated bytes into every decoder that
   sees peer data: frame parser, CBOR, `grpc-timeout`, `grpc-message`
   percent-decoding, method path parsing.
2. **Structure-aware.** Well-formed frames with one field mutated: a length
   that lies, a negative or huge count, a nesting depth of 10^5, an
   indefinite-length item that never ends, a stream id that was never opened,
   or one already closed.
3. **Stateful sequences against a real server.** Open, data, cancel,
   half-close, close and reconnect, in random order and interleaving, over a
   real transport (a real socket, a real isolate).

The oracles, all checked after every case:

- the process did not crash, and no error reached the root zone;
- the error was a typed refusal (`FormatException` or `RpcException`), never a
  `RangeError`, `StateError`, `StackOverflowError` or `TypeError`;
- peak resident memory stayed bounded;
- the status was correct, and so was its retryability (INTERNAL is final,
  RESOURCE_EXHAUSTED is retryable);
- **liveness: a fresh, ordinary call on a new connection still succeeds.** A
  fuzzer without this oracle misses every "the server is wedged" bug.

Dart has no coverage-guided fuzzer for the VM. Use seeded random generation
with a dictionary of interesting values (0, 1, 2^31-1, 2^32, 2^53+1, -1, the
limit-1/limit/limit+1 triple, max depth, empty, the 0xFF bytes). Record the
seed, so a failing case reproduces. Fuzz tests already in the gate are listed
in rpc-dart-surface.md. Extend those suites rather than starting a new one.

## 5. Conformance suites

Run the protocol's public conformance suite against both the client and the
server. These suites encode a decade of interop bugs.

- **WebSocket: Autobahn TestSuite** (`crossbario/autobahn-testsuite`, run in
  Docker). `fuzzingclient` mode tests a server, `fuzzingserver` mode tests a
  client. It covers framing, fragmentation, invalid UTF-8 in text frames,
  control frames inside fragmented messages, close codes, reserved bits,
  oversized payloads and permessage-deflate. It tests the dart:io WebSocket
  underneath, which is exactly the RPC-18 layer.
- **gRPC interop test cases**, from the gRPC repo's `doc/interop-test-descriptions.md`:
  `empty_unary`, `large_unary`, `client_streaming`, `server_streaming`,
  `ping_pong`, `empty_stream`, `cancel_after_begin`,
  `cancel_after_first_response`, `timeout_on_sleeping_server`,
  `custom_metadata`, `status_code_and_message`, `special_status_message`,
  `unimplemented_method`, `unimplemented_service`. Implementing the server
  half lets grpc-go and grpc-java clients drive rpc_dart.
- **HTTP/2: h2spec** (low priority here).

## 6. Differential testing against a reference

Send the same input to rpc_dart and to a reference implementation (grpc-go via
grpcurl, or a grpc-go server) and compare status, message, trailers and
timing. Disagreements are either rpc_dart bugs or documented choices. The
journal has rounds that call grpc-go and run grpcurl against rpc_dart; extend
them rather than starting over. Useful inputs: non-ASCII `grpc-message`,
`grpc-timeout` edge values, unknown methods, oversized metadata, a status
missing from the trailers.

## 7. Fault injection and network chaos

Correct code on a clean network says little. Use a TCP proxy that can inject
faults. Toxiproxy already appears in the journal: latency, bandwidth limits,
slicing into 1-byte writes, `reset_peer`, `timeout` (a black-holed
connection). Also:

- a half-open TCP connection: the peer vanishes and no FIN arrives (keepalive
  and idle timeouts must catch it);
- the process killed in the middle of a stream;
- a server restart shorter than, and longer than, the retry budget;
- a clock that jumps (deadlines must use a monotonic clock where the runtime
  offers one);
- a slow consumer, against a fast producer, on one shared connection.

## 8. Lifecycle and state-machine driving

Enumerate states and events for every object with a lifecycle (transport,
connection, endpoint, stream). Then drive them:

- each transition twice (close twice, start twice, reconnect twice) (RPC-21);
- out of order (send after close, close during connect, cancel before the
  first frame);
- concurrently (close racing a send, a reconnect racing a call);
- with an await in the middle: a flag read before an await and relied on after
  it (RPC-16);
- before the first listener subscribes (RPC-20).

A suite that drives each step once in the documented order is the blind spot.

## 9. Soak and leak accounting

Run N calls of each shape (unary, server stream, client stream, bidi), ending
each way (normal, cancel, deadline, error, peer disconnect). Compare live
timers, stream subscriptions, map sizes and RSS against a baseline taken after
warm-up (U-20). A count that grows with N is a leak, whatever its size per
call.

## 10. Dependency audit

- **What parses before you.** dart:io `WebSocket`, `HttpServer`,
  `package:http2`, `package:web_socket_channel`. Find what each one buffers,
  and whether your limits can act before it (RPC-18). Two of Dapr's three
  fuzzing findings were in dependencies.
- **Known CVEs.** `osv-scanner --lockfile=pubspec.lock` checks Pub packages
  against OSV. Run it at the workspace root.
- **Floors.** A transport that uses a new core API but declares an old
  `rpc_dart` floor (the release guide's step 1b) is a compatibility defect,
  not a security one.

## 11. Defaults and parity review

Make a matrix: every limit and timeout, by every transport, on both client and
server. Look for:

- a limit enforced on one transport only (RPC-08);
- a limit on the server but not the client. Malicious servers exist;
- a default that is off, or unbounded, or "null means no limit";
- a timeout hidden in a dependency (a 60-second constant nobody chose);
- insecure options that are opt-out instead of opt-in (compression, CORS `*`
  with credentials, TLS verification).

Secure by default means a user who sets nothing is protected.

## 12. Cross-runtime review

The web is a separate runtime (RPC-07). On dart2js:

- `int` is a double, exact only to 2^53. Lengths, ids and counters past that
  silently lose precision;
- cancelling an `async*` generator behaves differently;
- timers clamp, and `Stopwatch` resolution differs;
- `Random.secure` and `Isolate` are different or absent.

Run `melos run test:web` for every change that touches a shared layer.

## 13. Code-review hotspots

Shapes to look for when reading code that handles peer input:

- `BytesBuilder` or `List<int>.addAll` in a loop over peer chunks: unbounded,
  or quadratic on reassembly;
- `stream.toList()`, `fold` or `join` on a peer stream: unbounded;
- `utf8.decode`, `int.parse` or `jsonDecode` on peer data, without a size
  check first or a catch around it;
- a length prefix trusted before the bytes arrive: allocation by declared
  length;
- `catch (_) {}` around protocol handling: a refusal that turned into a
  continue (U-07);
- `Timer`, `StreamSubscription` or `StreamController` without a matching
  cancel or close on every exit path;
- `unawaited`, or a future with no error handler, on a peer-triggered path:
  an error reaches the zone (RPC-13);
- a warning logged on every frame for something the peer controls: log
  amplification;
- peer strings interpolated into logs or status messages: CRLF and control
  characters, and internals leaked back to the peer.

## 14. Identity and trust review

Cortex's 2026 audit found that a handler took the tenant id from the message
body, not from the authenticated context, so any caller could write as any
tenant. In an RPC framework, check:

- where the authenticated identity lives (the transport, `RpcContext`
  metadata, an interceptor), and whether the docs tell handler authors to read
  it from there and nowhere else;
- whether a peer can set metadata keys that the server treats as trusted
  (`x-user-id` and the like, or reserved `grpc-` and `rpc-` prefixes);
- whether context propagation to a downstream call forwards inbound
  credentials that should stop at this hop;
- whether auth state survives a reconnect it should not survive, or is lost
  when it should not be.
