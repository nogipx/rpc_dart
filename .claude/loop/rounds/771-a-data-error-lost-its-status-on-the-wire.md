---
round: 771
verdict: FIXED
packages: [rpc_data]
lens: RPC-23
bench: P-271 — new
commit: yes
release: changelog
severity: S2
---

# Round 771 — a data error lost its status on the wire

## Target

Seen in round 767: data errors cross the wire as INTERNAL. The narrative
says otherwise: `RpcDataError` carries a `status` and a `code`, the
responder's own comment says `notFound`, `conflict` and the rest "pass as
they are", and `rpc_data_sqlite`'s example catches a version conflict with
`on RpcDataError` from a `DataServiceClient`. The class: every exit of
`DataServiceResponder` (`_runSafely`, `exportDatabase`, `importDatabase`,
`watchChanges`, `_ensureAuthorized` outside `_runSafely`).

## Hypothesis

A remote client never receives an `RpcDataError`, and every data error
reaches it as status 13.

## Before

P-271:

```
  codec     conflict: RpcStatusException status=13 details=[]
  inmemory  conflict: RpcStatusException status=13 details=[]
```

## Mechanism

`wireStatusFor` forwards the status of an `RpcStatusException` only; any
other `RpcException` goes out as INTERNAL with its message. `RpcDataError`
extends `RpcException`, so its status never left the server, and the
client had nothing to rebuild it from. Fix, both ends:
`RpcDataError.toStatusException` (status, message, and a
`google.rpc.ErrorInfo` in domain `rpc_data` carrying the code and the
JSON-encoded details, never the cause) at every responder exit;
`RpcDataError.fromStatusException` in an interceptor `DataServiceClient`
installs on its endpoint once, for all four call shapes.

## After

```
  codec     conflict: RpcDataError status=10 code=VERSION_CONFLICT
  inmemory  conflict: RpcDataError status=10 code=VERSION_CONFLICT
```

## Canary

`packages/data/rpc_data/test/a_data_error_keeps_its_status_on_the_wire_test.dart`,
5 tests. One half at a time:

```
  responder half off   Actual: RpcStatusException(13): Expected version 6, got 1
  client half off      Actual: RpcStatusException(10): ... details:
                       [RpcErrorInfo(VERSION_CONFLICT, rpc_data)]
```

(3 of 5 fail in each; the two unit tests of the conversion do not depend
on either half.)

## The verdict questions

1. One arm, compared with what the server threw.
2. Yes: status 13 against 10.
3. At the client, as the exception caught.
4. n/a.
5. Yes, above.
6. Two halves, two canaries.
7. FIXED from the statuses.
8. Nothing dismissed. `DataRepositoryClient` wraps a local repository, so
   its errors never cross a wire.
9. A domain error type that is not the transport's status type loses its
   status at the boundary however carefully it is built: check what the
   wire mapping accepts, not what the type carries. Price: every remote
   data error since the service existed.
A1. One policy.
A2. n/a: a correctness defect.
L1. n/a.

## Gate

`melos run analyze`, `format:check`, `test:unit` green; rpc_data 62.

## Not fixed

A client built on a bare `DataServiceCaller`, without `DataServiceClient`,
gets the `RpcStatusException` with the `ErrorInfo`;
`RpcDataError.fromStatusException` is public for it.

## Links

Probe `../probes/P-271-what-a-remote-data-client-catches.md`.
Round `767-a-watcher-that-stops-reading-held-every-change.md`.
Lens `../lenses/RPC-23-the-narrative-beside-the-code.md`.
