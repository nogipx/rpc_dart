// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Bytes reserved in front of an encoded gRPC frame: the channel frame header.
///
/// A channel transport frames a gRPC frame a second time. Without room in
/// front it copies the whole message into a new buffer to put its header there;
/// with it, it writes the header in place.
const int kFrameHeadroom = 9;

/// Below this a frame gets no headroom. Copying a small frame is cheaper than
/// the [Expando] lookup that proves the headroom is ours.
const int kMinHeadroomFrame = 4096;

/// The whole buffer behind each view [allocateWithHeadroom] returned, until a
/// [claimHeadroom] takes it.
final Expando<Uint8List> _reserved = Expando<Uint8List>('frame headroom');

/// A zeroed list of [length] bytes, with [kFrameHeadroom] spare bytes before
/// it when it is at least [kMinHeadroomFrame] long.
Uint8List allocateWithHeadroom(int length) {
  if (length < kMinHeadroomFrame) return Uint8List(length);
  final whole = Uint8List(kFrameHeadroom + length);
  final view = Uint8List.sublistView(whole, kFrameHeadroom);
  _reserved[view] = whole;
  return view;
}

/// The whole buffer behind [frame], with [kFrameHeadroom] bytes free at its
/// start, when [frame] is exactly a list [allocateWithHeadroom] returned and its
/// headroom was not claimed before; otherwise null.
///
/// Once only: a frame sent twice would otherwise have its first header
/// overwritten while that send may still be queued.
Uint8List? claimHeadroom(Uint8List frame) {
  if (frame.length < kMinHeadroomFrame) return null;
  final whole = _reserved[frame];
  if (whole == null) return null;
  _reserved[frame] = null;
  return whole;
}
