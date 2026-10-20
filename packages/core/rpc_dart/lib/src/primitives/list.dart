// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Specialized list for objects implementing IRpcSerializable.
///
/// An [Iterable], so `for`-in and every collection method work on it, with
/// index access and in-place edits. Serialized as `{'items': [...]}`.
///
/// Not a [List] on purpose: a codec or `jsonEncode` writes a List as a bare
/// array, and a nested RpcList would then lose its `items` envelope.
class RpcList<T extends IRpcSerializable> extends IterableBase<T>
    implements IRpcSerializable {
  /// Backing list.
  final List<T> _items;

  /// Creates an empty list.
  RpcList() : _items = [];

  /// Creates a list from an existing collection.
  RpcList.from(List<T> items) : _items = List<T>.from(items);

  /// Creates a list of [length] elements, each set to [fill].
  ///
  /// Growable, like every other constructor here. It used to build a
  /// fixed-length list, so [add], [addAll], [remove], [removeAt] and [clear]
  /// — most of this wrapper's own API — threw `UnsupportedError` on the
  /// result. Nothing about serialising a list needs a fixed length, and a
  /// constructor that quietly returns a crippled instance is a trap.
  RpcList.filled(int length, T fill)
    : _items = List<T>.filled(length, fill, growable: true);

  /// Creates an empty growable list.
  RpcList.empty() : _items = List<T>.empty(growable: true);

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

  @override
  Iterator<T> get iterator => _items.iterator;

  @override
  int get length => _items.length;

  @override
  T elementAt(int index) => _items[index];

  /// The element at [index].
  T operator [](int index) => _items[index];

  /// Replaces the element at [index].
  void operator []=(int index, T value) => _items[index] = value;

  /// Adds [value] to the end.
  void add(T value) => _items.add(value);

  /// Adds every element of [items] to the end.
  void addAll(Iterable<T> items) => _items.addAll(items);

  /// Inserts [value] at [index].
  void insert(int index, T value) => _items.insert(index, value);

  /// Removes the first occurrence of [value]; true if there was one.
  bool remove(T value) => _items.remove(value);

  /// Removes and returns the element at [index].
  T removeAt(int index) => _items.removeAt(index);

  /// Removes every element.
  void clear() => _items.clear();

  /// Sorts in place with an optional comparator.
  void sort([int Function(T a, T b)? compare]) => _items.sort(compare);
}
