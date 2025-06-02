// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

/// Специализированный список для работы с объектами, реализующими IRpcSerializable
///
/// Предоставляет возможность сериализации/десериализации списка объектов,
/// при этом гарантируя типобезопасность и совместимость с RPC механизмами.
class RpcList<T extends IRpcSerializable> implements IRpcSerializable {
  /// Внутренний список объектов
  final List<T> _items;

  /// Создаёт пустой список
  RpcList() : _items = [];

  /// Создаёт список на основе существующего
  RpcList.from(List<T> items) : _items = List<T>.from(items);

  /// Создаёт список с заданным размером и заполняет его значениями
  RpcList.filled(int length, T fill) : _items = List<T>.filled(length, fill);

  /// Создаёт пустой список с указанной ёмкостью
  RpcList.empty({int capacity = 0}) : _items = List<T>.empty(growable: true);

  /// Создаёт список из JSON-представления
  ///
  /// [json] - JSON-представление списка
  /// [fromJson] - функция для создания объектов типа T из Map(String, dynamic)
  static RpcList<T> fromJsonRaw<T extends IRpcSerializable>(
    List<dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final list = RpcList<T>();
    for (final item in json) {
      if (item is Map<String, dynamic>) {
        list.add(fromJson(item));
      }
    }
    return list;
  }

  static RpcList<T> Function(
      Map<String, dynamic>) fromJson<T extends IRpcSerializable>(
    T Function(Map<String, dynamic>) fromJson,
  ) =>
      (Map<String, dynamic> json) => fromJsonRaw<T>(json['items'], fromJson);

  @override
  Map<String, dynamic> toJson() {
    return {'items': _items.map((item) => item.toJson()).toList()};
  }

  /// Длина списка
  int get length => _items.length;

  /// Проверка на пустоту
  bool get isEmpty => _items.isEmpty;

  /// Проверка, не пуст ли список
  bool get isNotEmpty => _items.isNotEmpty;

  /// Доступ к элементу по индексу
  T operator [](int index) => _items[index];

  /// Установка элемента по индексу
  void operator []=(int index, T value) {
    _items[index] = value;
  }

  /// Добавление элемента в конец списка
  void add(T value) {
    _items.add(value);
  }

  /// Добавление всех элементов из другого списка
  void addAll(Iterable<T> items) {
    _items.addAll(items);
  }

  /// Удаление элемента из списка
  bool remove(T value) {
    return _items.remove(value);
  }

  /// Удаление элемента по индексу
  T removeAt(int index) {
    return _items.removeAt(index);
  }

  /// Очистка списка
  void clear() {
    _items.clear();
  }

  /// Получение итератора
  Iterator<T> get iterator => _items.iterator;

  /// Получение внутреннего списка (неизменяемая копия)
  List<T> toList() => List.unmodifiable(_items);

  /// Получение внутреннего списка (модифицируемая копия)
  List<T> toMutableList() => List.from(_items);

  /// Преобразование в Iterable для удобного использования с методами коллекций
  Iterable<R> map<R>(R Function(T) f) => _items.map(f);

  /// Применение функции к каждому элементу
  void forEach(void Function(T) f) => _items.forEach(f);

  /// Фильтрация элементов
  RpcList<T> where(bool Function(T) test) {
    return RpcList<T>.from(_items.where(test).toList());
  }

  /// Сортировка списка по компаратору
  void sort([int Function(T a, T b)? compare]) {
    _items.sort(compare);
  }
}
