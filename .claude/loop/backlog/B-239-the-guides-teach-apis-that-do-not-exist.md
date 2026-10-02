---
status: open
round: 625
commit: ff258470
paths: [docs/guides/error-handling.md, docs/guides/context-and-metadata.md, docs/guides/rpc-lifecycle.md, packages/core/rpc_dart/lib/src/core/protocol.dart]
probe: none — audit probes `packages/core/rpc_dart/.dart_tool/probe/correct_wire_doc_constants.dart`, `correct_shapes_docs.dart`, not yet registered
reason: "cost — the guides name RpcStatus.OK and friends and four RpcContext factories that do not exist, and misstate what message a thrown exception produces"
---

# B-239 — the guides teach APIs that do not exist

Found by two auditors on 2026-10-02 (protocol, semantics), compiled before filing.

## Measured

Compiling the guides' snippets:

```
Member not found: 'OK', 'CANCELLED', 'DEADLINE_EXCEEDED'
Member not found: 'RpcContext.forDomainCall', 'forBusinessOperation',
  'createChain', 'extractDomainMetadata'
```

Real spellings are `RpcStatus.ok` etc. `error-handling.md` says any exception
becomes INTERNAL "using the message you provided": a plain `Exception('secret')`
arrives as `13: Internal server error` (default deny, correct), and an
`RpcException('Inventory check failed')` as `13: RpcException: Inventory check
failed`. `wireStatusFor`'s doc says forwarding `RpcException` is safe because
"every subclass is ours", but the class is public and non-final, and the guide
tells users to build it from application data.

## Owner decision

—
