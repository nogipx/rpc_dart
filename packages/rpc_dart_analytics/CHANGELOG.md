## 0.4.0

- Added per-event delivery hints that stay on-device and surface during upload
  so applications can route sealed batches to custom backends.
- Extended diagnostics snapshots to include delivery hints for easier
  verification during development.
- Migrated the local store to keep optional delivery metadata alongside
  encrypted tokens.

## 0.3.0

- Added fetch/acknowledge RPCs and a high-level `uploadPendingEvents()` helper
  for forwarding sealed analytics batches to backend services.

## 0.2.0

- Added opt-in diagnostics buffers with `RpcAnalyticsDiagnosticsOptions` and a
  new `diagnostics()` client API for inspecting recent events during
  development.

## 0.1.0

- Initial implementation of the isolate-backed analytics runtime with Licensify
  public-key sealed event storage.
