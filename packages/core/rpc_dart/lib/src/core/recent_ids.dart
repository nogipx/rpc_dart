// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:collection';

/// A set of the stream ids added most recently, bounded by [capacity].
///
/// An id is forgotten once [capacity] later ids have been added, or when it
/// is removed. Every operation is O(1): a `LinkedHashSet` evicting with
/// `remove(first)` walks the slots its own evictions left behind, on every
/// eviction.
final class RpcRecentIds {
  /// Creates an empty set that remembers at most [capacity] ids.
  RpcRecentIds(this.capacity);

  /// How many of the latest additions are remembered.
  final int capacity;

  /// Id to the sequence number of the addition that made it a member.
  final Map<int, int> _members = HashMap<int, int>();

  /// Additions in order, as id and sequence number; may name removed ids.
  final ListQueue<int> _ids = ListQueue<int>();
  final ListQueue<int> _seqs = ListQueue<int>();
  int _seq = 0;

  /// Number of ids remembered.
  int get length => _members.length;

  /// Whether [id] is remembered.
  bool contains(int id) => _members.containsKey(id);

  /// Remembers [id]; false if it already was.
  bool add(int id) {
    if (_members.containsKey(id)) return false;
    final seq = ++_seq;
    _members[id] = seq;
    _ids.add(id);
    _seqs.add(seq);
    while (_ids.length > capacity) {
      final old = _ids.removeFirst();
      final oldSeq = _seqs.removeFirst();
      // A removed id may have been added again since; only its own addition
      // ends its membership.
      if (_members[old] == oldSeq) _members.remove(old);
    }
    return true;
  }

  /// Forgets [id].
  void remove(int id) => _members.remove(id);

  /// Forgets every id.
  void clear() {
    _members.clear();
    _ids.clear();
    _seqs.clear();
  }
}
