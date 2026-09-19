---
round: 394
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-08
bench: P-83 — new
commit: yes
---

# Round 394 — the guard only one door had

## Target

The http2 responder, which the owner named as the next surface: *"the side
grpcurl and grpc-go hit directly"*. They had not covered it, nor
`http2_header_block_guard`.

The guard's own doc names an invariant with a silent failure mode —
*"[skipConnectionPreface] getting it backwards silently disables the guard in
one direction and corrupts parsing in the other"* — so that was checked first,
at both call sites. **It holds**: the server takes the default `true` (the
client sends the preface), the caller passes `false`. Not the defect.

The defect is one level up: **which doors the guard is fitted to.**

RPC-08 — a policy field inert on a neighbouring path. Its usual form is a
neighbouring TRANSPORT; here it is a neighbouring CONSTRUCTION PATH on the same
transport.

## Hypothesis

`RpcHttp2ResponderTransport` is exported and takes an already-built
`ServerTransportConnection`, so a user with their own accept loop gets no
header-block guard while their policy reads as enforced.

## Before

Same policy (`maxMetadataBytes: 64 KiB`), same 64 MiB flood — a HEADERS frame
with no END_HEADERS followed by 4096 CONTINUATION frames:

```
arm                             frames accepted   RSS
server (RpcHttp2Server)            65 of 4096     no growth
direct (own accept loop)         4096 of 4096     +178 MiB
```

Probe:
`rpc_dart_http2/.dart_tool/probe/guard_on_the_direct_path.dart` (P-83).

**Frames accepted is the number; RSS is not.** Across runs the flood arm read
+178 MiB and +27 MiB for the identical input — that is the GC, not the defect.
The frame count is deterministic and it is what the assertion uses.

The control is the server arm: the same flood, the same policy, one construction
path apart.

## Mechanism

`guardHttp2HeaderBlock` was applied in `RpcHttp2Server` and in the caller
transport. The responder transport receives a connection that already exists, so
it cannot guard bytes — by the time it is called, package:http2 is already wired
to the socket.

A user who accepts sockets themselves — for TLS, ALPN, or to share a port —
writes exactly what `RpcHttp2Server` writes minus the guard, and nothing says
so. Round 237's CONTINUATION flood is wide open there, below every rpc_dart
limit because no stream is created until END_HEADERS.

**And it is not only the guard.** The same block also sets
`SETTINGS_MAX_CONCURRENT_STREAMS` from `policy.maxActiveStreams`. Without it a
connection advertises package:http2's default of 1000 whatever the policy says,
so the knob is wrong in both directions — the reasoning was already written down
in the server and applied on one path only.

Two policy-derived protections, both attachable only at construction, both
missing from the exported door.

## After

```
arm                             frames accepted   RSS
server (RpcHttp2Server)            65 of 4096     no growth
direct (own accept loop, raw)    4096 of 4096     unbounded
direct via overStreams             65 of 4096     no growth
```

`RpcHttp2ResponderTransport.overStreams` builds the connection from a socket's
streams, applying the guard and the advertised limit. **And `RpcHttp2Server` now
goes through it**, so there is one construction path rather than two — the
correction this session has been making everywhere else (B-56, RPC-25).
`_advertisedStreamLimit` and its reasoning moved with it; nothing was left
behind as a tombstone.

The raw `connection:` constructor stays, because a user may legitimately hold a
connection this library did not build. Its doc now says what it cannot enforce
and points at the other door.

## Canary

The guard removed from the factory:

```
WITNESS: overStreams bounds a CONTINUATION flood
  Expected: a value less than <512>
    Actual: <512>
  the peer opened a header block and never ended it, and all 512 of 512 frames
  were buffered below every rpc_dart limit
```

Its GUARD — an ordinary Echo call through `overStreams` — stayed green, so the
guard is not simply breaking traffic. And the server's own flood test
(`continuation_flood_bounded_test`) passes after the refactor, which is the
check that routing it through the factory changed nothing.

## Gate

`melos run analyze` clean over 21 packages + wasm — it caught an unnecessary
import in the new test; `format:check` clean; `license:check` compliant;
workspace suite **SUCCESS in all 15 packages**, rpc_dart_http2 **+221 ~1** (was
+219).

## Not fixed

Nothing found in the responder's refusal paths this round — `_answerRejectedStream`
already answers, trims its own message against the policy that produced it, and
is detached with its own guard.

The owner's remaining uncovered list stands: the http2 responder's 1020 lines
beyond construction, `rpc_http2_server` past `_handleConnection`,
`websocket_io_connections`, `rpc_websocket_server`.

One thing for the owner, one line per the config's scope rule: this adds a
public factory and a public getter to an exported class, which is a minor bump
whenever the next release happens.

## Links

- RPC-08 — the lens; `applied:` gains 394. First application since 205, and it
  widens: the neighbour can be a construction PATH, not only a transport
- P-83 — the bench; its number is frames accepted, not RSS
- Round 237 — the flood this leaves open on the unguarded door
- B-56 — the same "one mechanic, several copies" this round closes for http2
  construction
