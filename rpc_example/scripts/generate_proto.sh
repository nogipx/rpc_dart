#!/bin/bash

# Скрипт для генерации Dart классов из .proto файлов

set -e

echo "🔧 Генерация Dart классов из protobuf..."

# Проверяем наличие protoc
if ! command -v protoc &> /dev/null; then
    echo "❌ protoc не найден. Установите Protocol Buffers compiler:"
    echo "   brew install protobuf  # на macOS"
    echo "   apt-get install protobuf-compiler  # на Ubuntu"
    exit 1
fi

# Проверяем наличие плагина protoc-gen-dart
if ! command -v protoc-gen-dart &> /dev/null; then
    echo "❌ protoc-gen-dart не найден. Установите:"
    echo "   dart pub global activate protoc_plugin"
    exit 1
fi

# Создаем папку для сгенерированных файлов
mkdir -p lib/generated

# Генерируем Dart классы
echo "📦 Генерируем классы из user_service.proto..."
protoc \
    --dart_out=lib/generated \
    --proto_path=protos \
    protos/user_service.proto

echo "✅ Генерация завершена! Файлы созданы в lib/generated/"
echo "📁 Созданные файлы:"
find lib/generated -name "*.dart" -type f | sort 