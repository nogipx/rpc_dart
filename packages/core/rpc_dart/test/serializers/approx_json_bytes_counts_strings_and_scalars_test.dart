// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Message implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {'text': 'hello', 'n': 1};
}

void main() {
  test('strings count their code units, other scalars 8, null 0', () {
    expect(approxJsonBytes('hello'), 5);
    expect(approxJsonBytes(42), 8);
    expect(approxJsonBytes(true), 8);
    expect(approxJsonBytes(null), 0);
  });

  test('maps count keys and values, lists their items', () {
    expect(
      approxJsonBytes({
        'ab': 'cde',
        'list': [1, 'xy', null],
      }),
      2 + 3 + 4 + 8 + 2,
    );
  });

  test('a serializable message counts as its JSON form', () {
    expect(approxJsonBytes(_Message()), 4 + 5 + 1 + 8);
  });
}
