# rpc_dart_data readiness review for small deployments

## Scope and methodology
- Reviewed the public documentation to understand the intended feature set, deployment model and operational assumptions of `rpc_dart_data`.【F:packages/rpc_dart_data/README.md†L14-L176】
- Inspected the current CLI bootstrap (`ServeCli`) to see which operational toggles are exposed and how the service is configured at runtime.【F:packages/rpc_dart_data/lib/src/cli/serve_cli.dart†L14-L200】
- Analysed the data access layer (`BaseDataRepository` and `DriftDataStorageAdapter`) to assess durability guarantees, query efficiency and change-stream behaviour.【F:packages/rpc_dart_data/lib/src/data_repository.dart†L84-L771】【F:packages/rpc_dart_data/lib/src/drift_storage.dart†L13-L200】
- Cross-referenced the existing production-readiness roadmap to confirm which limitations are acknowledged and what remediation steps are planned.【F:docs/rpc_dart_data/production_readiness.md†L1-L84】

## Strengths
- **Complete CRUD surface with extras.** The service exposes create/read/update/delete, batch upserts/deletes, search, aggregations, snapshot export/import and optimistic versioning, which covers typical SaaS-style workloads.【F:packages/rpc_dart_data/README.md†L16-L166】
- **Self-contained CLI bootstrap.** `ServeCli` handles port/host selection, daemonisation, PID files, verbose logging, secure wrap transport setup, relay integration and SQLCipher key parsing, so a small team can script deployments without writing their own wrapper.【F:packages/rpc_dart_data/lib/src/cli/serve_cli.dart†L21-L200】
- **SQLite storage with optional encryption.** The Drift-backed adapter automatically creates collection tables on demand, can open an encrypted SQLCipher database, adds indexes for hot columns and now persists the change journal so cursors survive restarts.【F:packages/rpc_dart_data/lib/src/drift_storage.dart†L29-L620】
- **Server-side pagination and atomic bulk ops.** `list()` delegates filters/sort/pagination into SQL, and bulk imports/upserts are applied transactionally, which keeps latency predictable on collections with tens of thousands of records.【F:packages/rpc_dart_data/lib/src/data_repository.dart†L308-L520】【F:packages/rpc_dart_data/lib/src/drift_storage.dart†L200-L420】

## Remaining considerations before launch
- **Backups remain manual.** `exportDatabase`/`importDatabase` cover the data path, but there is no turnkey CLI command yet; schedule cron jobs or container sidecars to copy JSON snapshots until the automation lands.【F:packages/rpc_dart_data/README.md†L210-L260】【F:docs/rpc_dart_data/production_readiness.md†L1-L120】
- **Edge security остаётся базовой.** Белый список bearer токенов теперь задаётся через CLI, но всё ещё нет ротации ключей, rate limiting и TLS — размещайте сервис за reverse proxy/API шлюзом, который возьмёт на себя шифрование и защиту от злоупотреблений.【F:packages/rpc_dart_data/README.md†L24-L112】

## Recommendation
The current single-node profile is ready for small-to-medium deployments (≈10k daily active users) provided you front it with an ingress proxy and schedule periodic backups. Drift-based storage now gives durable change streams, indexed queries and transactional bulk writes out of the box. Focus upcoming work on operational tooling (backup/restore CLI, retention policies) rather than core correctness.
