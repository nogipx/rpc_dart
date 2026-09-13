---
file: packages/core/rpc_dart/.dart_tool/probe/three_core_diagnostics.dart
round: 360
commit: 7a3c66d5
paths: [packages/core/rpc_dart/lib/src/core/**, packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-51 — three places the library answers wrongly rather than failing

One file, three sections, because the three defects grouped as review item 14
share a shape: each produces a WRONG ANSWER where a SIBLING right next to it
gets the same question right. Run it whole; each section is independent.

## Measures

Per section, on the library's side:

- **a** the first three ids a manager issues, per route into "resume this
  sequence".
- **b** whether a dotted service name survives a full round trip.
- **c** the exact message text a decompression failure produces.

## Control

**Each section's control is the sibling that gets it right**, which is what
makes the defect legible instead of merely surprising:

- `resumeAfter()` the METHOD, whose doc promises parity alignment, against the
  constructor parameter.
- `_parseMethodPath`, whose token pattern `[A-Za-z0-9_.-]+` explicitly ADMITS
  dots, against `_methodPathFromKey`, which cannot round-trip them.
- what the gzip codec actually threw, against what the parser reported.

```
a) route                       resumeAfter  first three ids
   method resumeAfter(4)       4            7, 9, 11     control
   constructor resumeAfter: 4  4            6, 8, 10  -> 7, 9, 11
   constructor, server         5            7, 9, 11  -> 8, 10, 12
   method, server              5            8, 10, 12    control

b) service name                answered as
   Calculator                  ok           control
   myapp.v1.UserService        ok
   google.protobuf.Empty       ok

c) input                       message
   a bomb (valid gzip header)  ...exceeds the configured limit (max: N)
   corrupt / not gzip at all   ...exceeds the configured limit (max: N)
                            -> ...could not be decompressed: it is malformed,
                               or it expands beyond the configured limit
```

**Section b came back CLEAN and is kept in the bench for that reason.** A dotted
service name round-trips through the ordinary path, because `methodPath` is
carried on the frame and `_methodPathFromKey` is only consulted when no metadata
message was retained. Deleting the arm would leave the next round re-deriving
that the happy path is fine; the negative is the result.
