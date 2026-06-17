#!/usr/bin/env just --justfile
pubget_all:
  for dir in packages/*/*; do \
    [ -f "$dir/pubspec.yaml" ] || continue; \
    echo "pub get -> $dir"; \
    if grep -q '^flutter:' "$dir/pubspec.yaml"; then \
      (cd "$dir" && fvm flutter pub get); \
    else \
      (cd "$dir" && fvm dart pub get); \
    fi; \
  done

upgrade_rpc_dart_all:
  version=$(awk '/^version:/{print $2}' packages/core/rpc_dart/pubspec.yaml); \
  echo "Updating rpc_dart dependency to ^${version}"; \
  for file in packages/*/*/pubspec.yaml; do \
    [ "$file" = "packages/core/rpc_dart/pubspec.yaml" ] && continue; \
    if grep -qE '^  rpc_dart:[ \t]+\^?[0-9]' "$file"; then \
      echo "  -> $file"; \
      perl -0pi -e "s/^(\\s*rpc_dart:[ \\t]+)\\^?[^\\s#\\n]+/\\1^${version}/m" "$file"; \
    fi; \
  done

# Cross-platform (dart2js/web) regression guard. The web-relevant packages and
# their web smoke tests MUST stay green on the `node` platform. Run before release.
test_web:
  cd packages/core/rpc_dart && fvm dart test -p node
  cd packages/core/rpc_dart_compression && fvm dart test -p node
  cd packages/core/rpc_dart_grpc_reflection && fvm dart test -p node
  cd packages/core/rpc_dart_opentelemetry && fvm dart test -p node test/web_smoke_test.dart
  cd packages/transport/rpc_dart_websocket && fvm dart test -p node test/websocket_web_smoke_test.dart
  cd packages/transport/rpc_dart_http && fvm dart test -p node test/web_smoke_test.dart
  cd packages/core/rpc_dart_log && fvm dart test -p node test/client_web_smoke_test.dart
  cd packages/data/rpc_data && fvm dart test -p node test/web_smoke_test.dart
  cd packages/blob/rpc_blob && fvm dart test -p node test/web_smoke_test.dart
  cd packages/data/rpc_data_sqlite && fvm dart test -p node test/web_smoke_test.dart
  cd packages/blob/rpc_blob_sqlite && fvm dart test -p node test/web_smoke_test.dart
  # Isolate web variant (Web Workers) needs browser globals -> chrome, not node.
  # Real e2e needs the worker pre-compiled; target browser test files explicitly.
  cd packages/transport/rpc_dart_isolate && fvm dart compile js test/web_worker/echo_worker.dart -o test/web_worker/echo_worker.dart.js && fvm dart test -p chrome test/web_smoke_test.dart test/web_worker/echo_worker_test.dart

docs:
  mkdocs serve --strict

# Regenerate widlet binary codec seed strings from WidletWidgetType + prop DTOs.
widlet_seed_strings:
  cd widlet/widlet_protocol && fvm dart run tool/generate_seed_strings.dart

upgrade_rpc_dart_generator_all:
  version=$(awk '/^version:/{print $2}' packages/core/rpc_dart_generator/pubspec.yaml); \
  echo "Updating rpc_dart_generator dependency to ^${version}"; \
  for file in packages/*/*/pubspec.yaml; do \
    [ "$file" = "packages/core/rpc_dart_generator/pubspec.yaml" ] && continue; \
    if grep -qE '^  rpc_dart_generator:[ \t]+\^?[0-9]' "$file"; then \
      echo "  -> $file"; \
      perl -0pi -e "s/^(\\s*rpc_dart_generator:[ \\t]+)\\^?[^\\s#\\n]+/\\1^${version}/m" "$file"; \
    fi; \
  done
