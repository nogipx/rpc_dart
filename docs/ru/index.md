# RPC Dart

[![Pub Version](https://img.shields.io/pub/v/rpc_dart.svg?style=for-the-badge&logo=dart&logoColor=white&color=3c69aa)](https://pub.dev/packages/rpc_dart)
[![GitHub Stars](https://img.shields.io/github/stars/nogipx/rpc_dart?style=for-the-badge&logo=github&logoColor=white&color=24292e)](https://github.com/nogipx/rpc_dart)
[![Pub Likes](https://img.shields.io/pub/likes/rpc_dart?style=for-the-badge&logo=dart&logoColor=white&color=86c3f4)](https://pub.dev/packages/rpc_dart)

> 📦 **{{ pub_downloads() }}** установок за последние 30 дней на [pub.dev]({{ pub_package_url() }}).

RPC Dart — транспортонезависимая библиотека RPC на чистом Dart. Она позволяет
писать сервисы один раз и запускать их на мобильных, веб, десктопных и
серверных платформах без привязки к конкретному транспорту или формату
серилизации.

## Быстрый старт

Установите пакет:

```sh
dart pub add rpc_dart
```

Для Flutter-проектов:

```sh
flutter pub add rpc_dart
```

Дополнительные транспорты (HTTP, WebSocket, Isolate):

```sh
dart pub add rpc_dart_transports
```

Подробнее см. в разделе [«Быстрый старт»](getting-started.md).

## Почему RPC Dart

- **Независимость от транспорта** — переключайтесь между InMemory, HTTP/2,
  WebSocket и Isolate без изменений бизнес-логики.
- **Чистая реализация на Dart** — никаких внешних зависимостей; работает везде,
  где работает Dart.
- **Все паттерны RPC** — унарные вызовы, клиентские и серверные потоки, а также
  двунаправленная потоковая передача.
- **Нулевая копия** — InMemory-транспорт передаёт объекты по ссылке для
  максимальной производительности и удобного тестирования.

## Полезные ссылки

- [Быстрый старт](getting-started.md)
- [Основные концепции](core-concepts.md)
- [Архитектура](architecture.md)
- [Репозиторий проекта](https://github.com/nogipx/rpc_dart)
- [Пакет на pub.dev](https://pub.dev/packages/rpc_dart)
