# 🧪 Руководство по тестированию RPC Dart

## Быстрые команды для разработки

### 🚀 Быстрые unit тесты (для ежедневной разработки)
```bash
# Только unit тесты - БЫСТРО! (~3-8 секунд)
dart test --tags=unit

# Или исключить медленные тесты
dart test --exclude-tags=performance,concurrency
```

### 🔍 Smoke тесты конкуренции (быстрая проверка)
```bash
# Smoke тесты конкуренции - умеренно быстро (~5-10 секунд)
dart test --tags=smoke
```

### 🏋️ Полные performance тесты
```bash
# Полные тесты производительности - МЕДЛЕННО! (~30+ секунд)
dart test --tags=performance

# Или полные тесты конкуренции
dart test --tags=concurrency
```

### 🎯 Все тесты (для CI/CD)
```bash
# Все тесты включая performance
dart test
```

## Структура тестов

```
test/
├── unit/                    # @Tags(['unit']) - быстрые unit тесты
├── concurrency/
│   ├── rpc_concurrency_smoke_test.dart  # @Tags(['unit', 'smoke']) - быстро
│   └── rpc_concurrency_test.dart        # @Tags(['performance']) - медленно
└── integration/             # @Tags(['integration']) - интеграционные тесты
```

## Примеры использования в IDE

### VS Code
1. Открыть Settings (Cmd/Ctrl + ,)
2. Найти "dart.flutterTestAdditionalArgs"
3. Добавить: `["--exclude-tags=performance,concurrency"]`

### IntelliJ IDEA
1. Run/Debug Configurations
2. Dart Test
3. Additional arguments: `--exclude-tags=performance,concurrency`

### Cursor/любой редактор
```bash
# Добавить в tasks.json или Makefile
"test:fast": "dart test --exclude-tags=performance,concurrency",
"test:smoke": "dart test --tags=smoke",  
"test:perf": "dart test --tags=performance"
```

## Временные характеристики

| Тип теста | Время выполнения | Когда использовать |
|-----------|------------------|-------------------|
| `--tags=unit` | ~3-8 сек | После каждого изменения кода |
| `--tags=smoke` | ~5-10 сек | Перед коммитом |
| `--tags=performance` | ~30+ сек | Перед релизом, в CI/CD |
| Все тесты | ~40+ сек | В CI/CD, еженедельно |

## Тэги в коде

### Unit тесты (быстрые)
```dart
@Tags(['unit'])
import 'package:test/test.dart';

void main() {
  test('quick unit test', () {
    // Быстрый тест без IO операций
  });
}
```

### Smoke тесты (умеренно быстрые)
```dart
@Tags(['unit', 'smoke'])  
import 'package:test/test.dart';

void main() {
  test('smoke test with light IO', () {
    // Легкая проверка интеграции
  });
}
```

### Performance тесты (медленные)
```dart
@Tags(['performance', 'concurrency'])
import 'package:test/test.dart';

void main() {
  test('heavy load test', () {
    // Тяжелые нагрузочные тесты
  });
}
```

## Философия тестирования

### 🏃‍♂️ Unit тесты - для скорости разработки
- Время выполнения: < 10 секунд
- Запускаются при каждом изменении
- Покрывают бизнес-логику и edge cases
- Без реальных IO операций

### 🌬️ Smoke тесты - для уверенности
- Время выполнения: < 15 секунд  
- Запускаются перед коммитом
- Базовые интеграционные проверки
- Минимальные IO операции

### 🏋️ Performance тесты - для качества
- Время выполнения: > 30 секунд
- Запускаются в CI/CD
- Проверяют производительность и надежность
- Полная нагрузка системы

## Makefile для удобства

```makefile
# Добавить в Makefile проекта
test-fast:
	dart test --exclude-tags=performance,concurrency

test-smoke:  
	dart test --tags=smoke

test-unit:
	dart test --tags=unit
	
test-perf:
	dart test --tags=performance

test-all:
	dart test
```

## Настройка git hooks

```bash
# pre-commit hook - быстрые тесты
#!/bin/sh
dart test --tags=unit
if [ $? -ne 0 ]; then
  echo "❌ Unit tests failed!"
  exit 1
fi

# pre-push hook - smoke тесты  
#!/bin/sh
dart test --tags=smoke
if [ $? -ne 0 ]; then
  echo "❌ Smoke tests failed!"
  exit 1  
fi
```

## Советы по оптимизации

1. **Используйте in-memory transport** для unit тестов
2. **Минимизируйте Future.delayed()** в быстрых тестах
3. **Группируйте setup/tearDown** для переиспользования
4. **Мокайте внешние зависимости** в unit тестах
5. **Используйте setUpAll()** для дорогих инициализаций 