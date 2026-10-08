---
round: 741
verdict: CLEAN
packages: [rpc_dart_http2, rpc_dart_grpc_reflection]
lens: RPC-15
bench: P-245 — reused
commit: yes
release: none
---

# Round 741 — grpcurl streams and TLS

## Target

Round 740's "Not fixed": client-streaming and bidi through a real client,
and TLS. These are the two halves of gRPC interop that 740 did not drive.

## Hypothesis

A real client fails on client-streaming, on bidi, or on h2 over TLS with
ALPN. Or the TLS listener holds a socket that spoke plaintext until a timeout.

## Before

P-245 (`r740_grpcurl.dart`, requests on stdin with `-d @`) and
`r741_grpcurl_tls.dart` (a self-signed certificate made by `openssl` for the
run):

```
  Join  (client stream) <<< a, b, c        exit 0   {"text": "a+b+c"}
  Shout (bidi)          <<< x, y           exit 0   X, Y
  TLS   grpcurl -insecure list             exit 0   e.S
  TLS   grpcurl -plaintext list (control)  exit 1   failed to dial
  raw plaintext h2 preface to the TLS
    listener                               closed by the server after 1 ms
```

## Mechanism

None. The plaintext client's "context deadline exceeded" is grpcurl
retrying its dial, not the server holding the socket: the server closes in
1 ms.

## After

n/a.

## Canary

n/a — no fix. The plaintext arm is the control: it shows the TLS arm's
success is TLS and not an open listener.

## The verdict questions

1. Yes: TLS and plaintext against the same listener.
2. Yes: exit 0 against exit 1.
3. At grpcurl, and a raw socket for the close.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. grpcurl has its own configuration.
A2. n/a.
L1. n/a.

## Gate

No library change.

## Not fixed

Mutual TLS was not driven.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 741]`.
Bench `../probes/P-245-grpcurl-against-rpc-dart.md` — streaming arms and the
TLS probe added.
