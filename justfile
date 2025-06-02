#!/usr/bin/env just --justfile

# === ЗАВИСИМОСТИ ===
test:
    fvm dart test

get:
    rm -f rpc_example/pubspec.lock
    rm -rf rpc_example/.dart_tool

    rm -f rpc_dart_transports/pubspec.lock
    rm -rf rpc_dart_transports/.dart_tool

    rm -f rpc_dart/pubspec.lock
    rm -rf rpc_dart/.dart_tool

    rm -rf .dart_tool

    fvm dart pub global run packo pubget -r

gen:
    rm -f rpc_example/pubspec.lock
    rm -rf rpc_example/.dart_tool

    rm -f rpc_dart_transports/pubspec.lock
    rm -rf rpc_dart_transports/.dart_tool

    rm -f rpc_dart/pubspec.lock
    rm -rf rpc_dart/.dart_tool

    rm -rf .dart_tool

    fvm dart pub global run packo runner -r

# === СБОРКА ===
compile:
    cd rpc_example && rm pubspec.lock
    cd rpc_example && fvm dart pub get
    cd rpc_example && fvm dart compile exe bin/main.dart -o bin/examples
    cd rpc_example && chmod +x bin/examples

# Локальная сборка роутера (быстрее чем CI)
build-router:
    cd rpc_dart_transports && mkdir -p build
    cd rpc_dart_transports && fvm dart pub get
    cd rpc_dart_transports && fvm dart compile exe bin/rpc_dart_router.dart -o build/rpc_dart_router
    cd rpc_dart_transports && chmod +x build/rpc_dart_router

# Запуск роутера с базовыми настройками для тестирования
run-router port="11111":
    cd rpc_dart_transports && just build-router
    cd rpc_dart_transports && ./build/rpc_dart_router --port {{port}}

# === ДЕМО И ТЕСТИРОВАНИЕ ===
demo_server:
    cd rpc_example/bin/integration && fvm dart run demo_server.dart

demo_client:
    cd rpc_example/bin/integration && fvm dart run demo_client.dart

demo_diagnostic:
    cd rpc_example/bin/integration && fvm dart run diagnostic_service.dart

# Запуск чата для тестирования
run-chat:
    cd rpc_dart_chat && fvm flutter run -d chrome

# === ОЧИСТКА ===
clean:
    rm -rf rpc_dart_transports/build/
    rm -rf rpc_example/bin/examples
    rm -rf .dart_tool/
    find . -name "*.lock" -delete
    find . -name ".dart_tool" -type d -exec rm -rf {} +