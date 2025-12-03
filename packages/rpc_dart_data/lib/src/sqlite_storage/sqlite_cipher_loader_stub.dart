/// No-op stub for platforms without FFI (e.g., web).
void configureSqlCipherDynamicLibrary({String? libraryPath}) {
  libraryPath;
}

bool get isSqlCipherAvailable => false;
