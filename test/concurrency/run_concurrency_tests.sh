#!/bin/bash

# Скрипт для запуска тестов конкуренции RPC системы
# Usage: ./run_concurrency_tests.sh [options]

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Конфигурация по умолчанию
VERBOSE=false
QUICK_MODE=false
FILTER=""

# Функция для показа помощи
show_help() {
    echo "🧪 RPC Concurrency Test Runner"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose     Verbose output (показать все детали)"
    echo "  -q, --quick       Quick mode (быстрые тесты, пропустить stress testing)"
    echo "  -f, --filter=PATTERN  Запустить только тесты, содержащие PATTERN"
    echo "  -h, --help        Показать эту справку"
    echo ""
    echo "Examples:"
    echo "  $0                          # Запустить все тесты"
    echo "  $0 -v                       # Запустить с подробным выводом"
    echo "  $0 -q                       # Быстрые тесты"
    echo "  $0 -f 'Basic Concurrency'   # Только базовые тесты конкуренции"
    echo "  $0 -f 'Stress'              # Только stress тесты"
    echo ""
}

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quick)
            QUICK_MODE=true
            shift
            ;;
        -f|--filter)
            FILTER="$2"
            shift 2
            ;;
        --filter=*)
            FILTER="${1#*=}"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${BLUE}🚀 Starting RPC Concurrency Tests${NC}"
echo "================================="

# Проверяем, что мы в правильной директории
if [[ ! -f "pubspec.yaml" ]]; then
    echo -e "${RED}❌ Error: pubspec.yaml not found. Please run from project root.${NC}"
    exit 1
fi

# Переходим в директорию проекта
cd "$(dirname "$(dirname "$(dirname "$0")")")"

echo -e "${YELLOW}📋 Configuration:${NC}"
echo "  Verbose: $VERBOSE"
echo "  Quick mode: $QUICK_MODE"
if [[ -n "$FILTER" ]]; then
    echo "  Filter: '$FILTER'"
fi
echo ""

# Формируем команду dart test
DART_TEST_CMD="dart test"

# Добавляем путь к тестам
DART_TEST_CMD="$DART_TEST_CMD test/concurrency/rpc_concurrency_test.dart"

# Добавляем verbose флаг если нужен
if [[ "$VERBOSE" == "true" ]]; then
    DART_TEST_CMD="$DART_TEST_CMD -v"
fi

# Добавляем фильтр если указан
if [[ -n "$FILTER" ]]; then
    DART_TEST_CMD="$DART_TEST_CMD --name='$FILTER'"
fi

# Если quick mode, пропускаем stress тесты
if [[ "$QUICK_MODE" == "true" ]]; then
    if [[ -n "$FILTER" ]]; then
        # Если уже есть фильтр, то не меняем его
        echo -e "${YELLOW}⚡ Quick mode: using existing filter${NC}"
    else
        # Иначе исключаем stress тесты
        DART_TEST_CMD="$DART_TEST_CMD --name='(?!.*Stress)'"
        echo -e "${YELLOW}⚡ Quick mode: skipping Stress Testing group${NC}"
    fi
fi

echo -e "${BLUE}🎯 Running command:${NC} $DART_TEST_CMD"
echo ""

# Запускаем тесты
start_time=$(date +%s)

if eval "$DART_TEST_CMD"; then
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo ""
    echo -e "${GREEN}✅ All concurrency tests passed!${NC}"
    echo -e "${GREEN}📊 Test duration: ${duration}s${NC}"
    
    echo ""
    echo -e "${BLUE}📈 Performance Summary:${NC}"
    echo "• Check the test output above for detailed latency and throughput metrics"
    echo "• Look for patterns in concurrent behavior under different loads"
    echo "• Note any error rates and resource limitations detected"
    
    if [[ "$QUICK_MODE" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}💡 Tip: Run without -q flag to include stress testing for full analysis${NC}"
    fi
else
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo ""
    echo -e "${RED}❌ Some concurrency tests failed!${NC}"
    echo -e "${RED}📊 Test duration: ${duration}s${NC}"
    echo ""
    echo -e "${YELLOW}🔍 Debugging tips:${NC}"
    echo "• Check if the system is under high load"
    echo "• Review error patterns in the output above" 
    echo "• Consider running with -v flag for more details"
    echo "• Try -q flag for quick validation of basic functionality"
    
    exit 1
fi

echo ""
echo -e "${BLUE}🏁 Concurrency testing completed successfully!${NC}" 