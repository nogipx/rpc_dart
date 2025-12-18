// Postgres adapter is only available on IO; on web/JS it falls back to a stub.
export 'postgres_storage_adapter_unsupported.dart'
    if (dart.library.io) 'postgres_storage_adapter.dart';
