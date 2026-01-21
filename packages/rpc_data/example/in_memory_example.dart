// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data/rpc_data.dart';

Future<void> main() async {
  // Spin up a full in-memory environment: repository + caller/responder pair.
  final env = await DataServiceFactory.inMemory();
  final client = env.client;

  final created = await client.create(
    collection: 'notes',
    payload: {'title': 'Hello', 'done': false},
  );
  print('created: ${created.id} v=${created.version}');

  final listed = await client.list(
    collection: 'notes',
    options: const QueryOptions(limit: 5),
  );
  for (final record in listed.records) {
    print('note ${record.id}: ${record.payload}');
  }

  await env.dispose();
}
