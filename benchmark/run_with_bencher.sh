#!/bin/bash

# Скрипт для интеграции RPC Dart бенчмарка с Bencher.dev
# 
# Использование:
#   ./run_with_bencher.sh [--local] [--adapter=magic|json]
#   
# Флаги:
#   --local         - запуск только локально без отправки в Bencher
#   --adapter=TYPE  - адаптер для вывода (magic или json, по умолчанию json)
#
# Переменные окружения:
#   BENCHER_API_TOKEN - токен API Bencher
#   BENCHER_PROJECT   - проект в Bencher (по умолчанию: rpc-dart)
#   BENCHER_BRANCH    - ветка в Bencher (по умолчанию: main)
#   BENCHER_TESTBED   - testbed в Bencher (по умолчанию: local)

set -e

echo "🚀 Запуск RPC Dart бенчмарка с Bencher.dev"

# Настройки по умолчанию
PROJECT=${BENCHER_PROJECT:-"rpc-dart"}
BRANCH=${BENCHER_BRANCH:-"main"}
TESTBED=${BENCHER_TESTBED:-"local"}
ADAPTER="json"
LOCAL_ONLY=false

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
  case $1 in
    --local)
      LOCAL_ONLY=true
      shift
      ;;
    --adapter=*)
      ADAPTER="${1#*=}"
      shift
      ;;
    --help)
      echo "Использование: $0 [--local] [--adapter=magic|json]"
      echo ""
      echo "Флаги:"
      echo "  --local         - запуск только локально без отправки в Bencher"
      echo "  --adapter=TYPE  - адаптер для вывода (magic или json, по умолчанию json)"
      echo ""
      echo "Переменные окружения:"
      echo "  BENCHER_API_TOKEN - токен API Bencher"
      echo "  BENCHER_PROJECT   - проект в Bencher (по умолчанию: rpc-dart)"
      echo "  BENCHER_BRANCH    - ветка в Bencher (по умолчанию: main)"
      echo "  BENCHER_TESTBED   - testbed в Bencher (по умолчанию: local)"
      exit 0
      ;;
    *)
      echo "❌ Неизвестный аргумент: $1"
      echo "Используйте --help для справки"
      exit 1
      ;;
  esac
done

# Создаем директорию для результатов
mkdir -p benchmark_results

# Если запуск только локально
if [ "$LOCAL_ONLY" = true ]; then
    echo "🏃 Локальный запуск бенчмарка..."
    echo "📊 Настройки:"
    echo "   Адаптер: $ADAPTER"
    echo ""
    
    if [ "$ADAPTER" = "json" ]; then
        dart run benchmark/benchmark.dart --output=benchmark_results/local_results.json
        echo ""
        echo "✅ Бенчмарк завершен!"
        echo "📄 Результаты сохранены: benchmark_results/local_results.json"
    else
        dart run benchmark/benchmark.dart
        echo ""
        echo "✅ Бенчмарк завершен!"
    fi
    
    exit 0
fi

# Проверяем наличие bencher CLI
if ! command -v bencher &> /dev/null; then
    echo "❌ Bencher CLI не найден. Установите его:"
    echo "   cargo install bencher"
    echo "   или скачайте с https://bencher.dev/docs/how-to/install-cli/"
    exit 1
fi

# Проверяем токен API
if [ -z "$BENCHER_API_TOKEN" ]; then
    echo "❌ Установите BENCHER_API_TOKEN:"
    echo "   export BENCHER_API_TOKEN=your_token_here"
    echo "   Получить токен: https://bencher.dev/console/users/tokens"
    exit 1
fi

echo "📊 Настройки Bencher:"
echo "   Проект: $PROJECT"
echo "   Ветка: $BRANCH"  
echo "   Testbed: $TESTBED"
echo "   Адаптер: $ADAPTER"
echo ""

# Создаем проект если его нет
echo "🔧 Проверка проекта..."
bencher project create \
    --name "RPC Dart Performance" \
    --slug "$PROJECT" \
    --url "https://github.com/nogipx/rpc_dart" \
    --public 2>/dev/null || echo "   Проект уже существует или создание не удалось"

# Запускаем бенчмарк с Bencher
echo "🏃 Запуск бенчмарка через Bencher..."
bencher run \
    --project "$PROJECT" \
    --branch "$BRANCH" \
    --testbed "$TESTBED" \
    --adapter "$ADAPTER" \
    --file "benchmark_results/bencher_results.json" \
    --err \
    "dart run benchmark/benchmark.dart --output=benchmark_results"

echo ""
echo "✅ Бенчмарк завершен!"
echo "📊 Результаты доступны в Bencher Console:"
echo "   https://bencher.dev/console/projects/$PROJECT"
echo "🌐 Публичный дашборд:"
echo "   https://bencher.dev/perf/$PROJECT"
echo "📄 Локальные результаты: benchmark_results/bencher_results.json" 