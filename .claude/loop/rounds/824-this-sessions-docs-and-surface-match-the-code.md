---
round: 824
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http, rpc_dart_websocket]
lens: RPC-23
bench: none — a reading of each claim against a measurement this session already took
commit: yes
severity: S3
release: none
---

# Round 824 — this session's docs and public surface match the code

## Target

RPC-23 (#3, 39 of 43 rounds FIXED, last applied in round 771) on the prose
written since 3400b5f3: the http and websocket READMEs and three skill
references, 74 lines. With RPC-24 (#4) on the symbols those rounds added.

## Hypothesis

A sentence written with a fix describes the fix's intent rather than what
was measured, as round 822's reading of round 722 showed can happen.

## Before

Each added claim, and the measurement that stands behind it:

```
  claim                                                   checked against
  http: header block cut at ~270 KiB, 400 a little over   round 813 (P-299): 119 KB -> 400, 1 MB -> closed
  http: headerTimeout from accept / first byte            peer_watch _armDeadline, _admit
  http: pipelined blocks (not claimed)                    round 820: they wait in the kernel
  http: redirects not followed, web UNAVAILABLE           round 807 witnesses
  ws: connect failure table                               round 814 (P-300 after the fix)
  skill: frame channel oversize -> 8, then close          round 818 probe: status 8 at every cap
  skill: maxDecodedItems both directions, pre-interceptor round 803 witnesses (I-8)
  skill: forward() drops three headers                    RpcContext._credentialHeaders
  skill: derived withDeadline keeps the earlier one       round 805 witness
```

RPC-24, the symbols: `withCborItemBudget` and `CborItemLimitException` are
not exported (`codec/_index.dart` shows `CborCodec` only), and the doc says
the caller sees a `FormatException`, which `CborItemLimitException` is.
`PeerWatchingServerSocket` and `kRpcHttpPeerGoneKey` live in
`peer_watch.dart`, which `rpc_dart_http.dart` does not export.

## Mechanism

n/a (CLEAN).

## After

No claim without a measurement or a line of code under it; no symbol public
by accident.

## Canary

n/a, a reading. Every row above cites a measurement taken this session.

## The verdict questions

1. n/a (a reading).
2. n/a.
3. The docs against the code and the session's own measurements.
4. 74 lines, 9 claims.
5. n/a.
6. n/a.
7. CLEAN.
8. none.
9. none.
10. No code changed.
A1. n/a. A2. n/a. L1. n/a.

## Gate

No code changed.

## Siblings

No code changed.

## Not fixed

none.

## Links

Lens `../lenses/RPC-23-the-narrative-beside-the-code.md`.
