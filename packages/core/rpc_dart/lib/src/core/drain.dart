// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../logger/_index.dart';

/// Waits for a server's in-flight work to finish, up to [budget].
///
/// A graceful shutdown is: stop accepting, wait for what is already running,
/// then close. This is the middle step, and every [IRpcServer] needs it in the
/// same shape — poll a count until it reaches zero or the budget expires.
///
/// [pending] is what differs between servers and is therefore a parameter: a
/// connection-per-endpoint server counts live responder streams across its
/// endpoints, while a single-endpoint HTTP/1.1 server asks its transport how
/// many requests it has accepted and not yet answered. It may be sync or async.
///
/// [unit] names what is being counted in the log ("call", "request"), because
/// "3 in flight" is not worth reading without it.
///
/// **The budget is not optional and the wait is not a guarantee.** A peer can
/// keep sending, and a handler can simply run long, so this returns once the
/// budget expires whether or not the count reached zero — the caller closes
/// regardless. It logs the difference, which is the only way an operator learns
/// a deploy is cutting calls off.
///
/// What this deliberately does NOT do: stop accepting. That has to happen
/// BEFORE the drain, in the caller, or the count it polls can rise while it
/// waits and a busy server never converges.
Future<void> drainUntilIdle({
  required FutureOr<int> Function() pending,
  required Duration budget,
  LogScope? logger,
  String unit = 'call',
}) async {
  final deadline = DateTime.now().add(budget);
  var remaining = await pending();
  if (remaining == 0) return;

  logger?.info('Draining $remaining in-flight $unit(s) before shutdown');

  while (remaining > 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    remaining = await pending();
  }

  if (remaining > 0) {
    logger?.warning(
      'Drain budget $budget expired with $remaining $unit(s) still in flight; '
      'closing anyway',
    );
  } else {
    logger?.info('Drain complete; no $unit is in flight');
  }
}
