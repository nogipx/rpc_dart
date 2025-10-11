# rpc_dart_data readiness review for small deployments

## Scope and methodology
- Reviewed the public documentation to understand the intended feature set, deployment model and operational assumptions of `rpc_dart_data`.【F:packages/rpc_dart_data/README.md†L14-L176】
- Inspected the current CLI bootstrap (`ServeCli`) to see which operational toggles are exposed and how the service is configured at runtime.【F:packages/rpc_dart_data/lib/src/cli/serve_cli.dart†L14-L200】
- Analysed the data access layer (`BaseDataRepository` and `DriftDataStorageAdapter`) to assess durability guarantees, query efficiency and change-stream behaviour.【F:packages/rpc_dart_data/lib/src/data_repository.dart†L84-L771】【F:packages/rpc_dart_data/lib/src/drift_storage.dart†L13-L200】
- Cross-referenced the existing production-readiness roadmap to confirm which limitations are acknowledged and what remediation steps are planned.【F:docs/rpc_dart_data/production_readiness.md†L1-L84】

## Strengths
- **Complete CRUD surface with extras.** The service already exposes create/read/update/delete, batch upserts/deletes, text search, aggregations, snapshot export/import and optimistic versioning, which is sufficient for many internal tools or hobby projects.【F:packages/rpc_dart_data/README.md†L16-L166】
- **Self-contained CLI bootstrap.** `ServeCli` handles port/host selection, daemonisation, PID files, verbose logging, secure wrap transport setup, relay integration and SQLCipher key parsing, so a small team can script deployments without writing their own wrapper.【F:packages/rpc_dart_data/lib/src/cli/serve_cli.dart†L21-L200】
- **SQLite storage with optional encryption.** The Drift-backed adapter automatically creates collection tables on demand and can open an encrypted SQLCipher database when the PASERK key is supplied, which is attractive for single-host deployments with basic at-rest protection needs.【F:packages/rpc_dart_data/lib/src/drift_storage.dart†L29-L200】

## Material gaps for a 10k DAU service
- **Change streams are volatile.** The repository keeps the watch/sync journal only in memory; after restart there is no way to resume from a cursor, which breaks offline clients in case of crashes or updates.【F:packages/rpc_dart_data/lib/src/data_repository.dart†L96-L159】【F:packages/rpc_dart_data/README.md†L170-L176】
- **Query path requires full collection scans.** Both listing and search operations load the entire collection into memory and filter/sort client-side, so latency grows linearly with collection size and quickly becomes a bottleneck for >10–20k records per collection.【F:packages/rpc_dart_data/lib/src/data_repository.dart†L243-L336】【F:packages/rpc_dart_data/lib/src/data_repository.dart†L653-L735】 The roadmap already calls out the need for server-side indexes and query delegation.【F:docs/rpc_dart_data/production_readiness.md†L28-L66】
- **Bulk operations lack transactional safety.** `bulkUpsert`/`bulkDelete`/`importDatabase` iterate per record without wrapping the writes into a database transaction, so an exception midway leaves the collection in a partially-applied state.【F:packages/rpc_dart_data/lib/src/data_repository.dart†L485-L647】
- **Operational recovery story is incomplete.** There is no persistent change journal, no built-in backup/restore workflow beyond manual export/import, and the default factory still prefers in-memory storage over the file-backed adapter mentioned in docs.【F:docs/rpc_dart_data/production_readiness.md†L20-L47】 This means planned restarts or crashes can lead to data loss unless every deploy script wires the Drift file adapter explicitly.
- **Security model is minimal.** Server-side authentication currently trusts a single bearer header and there is no multi-tenant authorisation, audit logging, or rate limiting, so any exposed endpoint must sit behind additional infrastructure for access control and traffic shaping.【F:packages/rpc_dart_data/README.md†L24-L27】

## Recommendation
For a truly small hobby project with a few thousand lightweight records and lenient offline requirements, the current build can be run in production provided you accept the risks above and add your own backup/process supervision. However, sustaining 10k daily active users typically implies larger datasets, background sync clients and stricter recovery expectations. Until the persistent journal, indexed queries and transactional bulk operations from the roadmap are implemented, the service should be treated as pre-production.

Teams willing to invest in hardening can mitigate some gaps by:
1. Shipping a patched build where `DriftDataStorageAdapter.file` is the default, and wrapping repository bulk operations in explicit SQLite transactions.
2. Wiring an external job that periodically exports JSON snapshots and stores them off the host.
3. Fronting the service with an API gateway that enforces authn/z and applies request quotas.
4. Monitoring memory usage closely, because full-collection scans will scale poorly as data grows.

Absent those mitigations, adoption for a 10k DAU project is not recommended yet.
