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
