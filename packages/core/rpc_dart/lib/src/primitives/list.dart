// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Specialized list for objects implementing IRpcSerializable.
///
/// Provides serialization/deserialization while keeping type safety and RPC
/// compatibility.
class RpcList<T extends IRpcSerializable> implements IRpcSerializable {
  /// Backing list.
  final List<T> _items;

  /// Creates an empty list.
  RpcList() : _items = [];

  /// Creates a list from an existing collection.
  RpcList.from(List<T> items) : _items = List<T>.from(items);

  /// Creates a fixed-length list filled with [fill].
  RpcList.filled(int length, T fill) : _items = List<T>.filled(length, fill);

  /// Creates an empty growable list with optional capacity hint.
  RpcList.empty({int capacity = 0}) : _items = List<T>.empty(growable: true);

  /// Creates a list from a JSON representation.
  ///
  /// Every element must be a JSON object. An element that is not one is a
  /// [FormatException] rather than a silent omission: this used to skip such
  /// entries, so a decode could hand back a SHORTER list than was sent, with
  /// nothing anywhere to say so.
  static RpcList<T> fromJsonRaw<T extends IRpcSerializable>(
    List<dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final list = RpcList<T>();
    for (var i = 0; i < json.length; i++) {
      final item = json[i];
      if (item is Map<String, dynamic>) {
        list.add(fromJson(item));
        continue;
      }
      // Decoders other than this package's CBOR reader -- a custom IRpcCodec,
      // a protobuf bridge, anything building maps dynamically -- routinely
      // produce Map<dynamic, dynamic>. That failed the check above, so EVERY
      // element was dropped and a full list decoded to an empty one. Coerce
      // the keys instead; they are strings by construction on this path.
      if (item is Map) {
        list.add(fromJson(item.map((k, v) => MapEntry(k.toString(), v))));
        continue;
      }
      throw FormatException(
        'RpcList.fromJson: element $i is ${item.runtimeType}, expected a JSON '
        'object',
      );
    }
    return list;
  }

  /// Returns a decoder function that builds an [RpcList] from JSON.
  ///
  /// A missing `items` key yields an empty list (an absent field is not an
  /// error); an `items` that is present but not a list throws, rather than
  /// quietly decoding to empty.
  static RpcList<T> Function(Map<String, dynamic>) fromJson<
    T extends IRpcSerializable
  >(T Function(Map<String, dynamic>) fromJson) => (Map<String, dynamic> json) {
    final items = json['items'];
    if (items == null) return RpcList<T>();
    if (items is List) return fromJsonRaw<T>(items, fromJson);
    throw FormatException(
      'RpcList.fromJson: "items" is ${items.runtimeType}, expected a list',
    );
  };

  @override
  Map<String, dynamic> toJson() {
    return {'items': _items.map((item) => item.toJson()).toList()};
  }

  /// Length of the list.
  int get length => _items.length;

  /// True when the list is empty.
  bool get isEmpty => _items.isEmpty;

  /// True when the list is not empty.
  bool get isNotEmpty => _items.isNotEmpty;

  /// Indexer access.
  T operator [](int index) => _items[index];

  /// Sets a value by index.
  void operator []=(int index, T value) {
    _items[index] = value;
  }

  /// Adds an element to the end.
  void add(T value) {
    _items.add(value);
  }

  /// Adds all elements from another iterable.
  void addAll(Iterable<T> items) {
    _items.addAll(items);
  }

  /// Removes an element.
  bool remove(T value) {
    return _items.remove(value);
  }

  /// Removes by index.
  T removeAt(int index) {
    return _items.removeAt(index);
  }

  /// Clears the list.
  void clear() {
    _items.clear();
  }

  /// Returns an iterator.
  Iterator<T> get iterator => _items.iterator;

  /// Returns an unmodifiable copy.
  List<T> toList() => List.unmodifiable(_items);

  /// Returns a mutable copy.
  List<T> toMutableList() => List.from(_items);

  /// Maps items for convenient collection methods.
  Iterable<R> map<R>(R Function(T) f) => _items.map(f);

  /// Applies a function to each element.
  void forEach(void Function(T) f) => _items.forEach(f);

  /// Filters elements.
  RpcList<T> where(bool Function(T) test) {
    return RpcList<T>.from(_items.where(test).toList());
  }

  /// Sorts items with an optional comparator.
  void sort([int Function(T a, T b)? compare]) {
    _items.sort(compare);
  }
}
