// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

library;

export 'dart:typed_data';

export 'logger.dart';

/// The public surface.
///
/// `src/_index.dart` re-exports nine subdirectory barrels wholesale, so without
/// this `hide` "public" means "declared without an underscore".
///
/// What is hidden is machinery nothing outside this package uses — measured,
/// not guessed. `RpcMessageParser`, `RpcMessageHeader` and
/// `BufferedBroadcastController` are deliberately NOT hidden: all four
/// transports build on them, which makes them the transport-authoring API.
///
/// Narrowing this was only possible once `lib/` stopped importing it; the
/// implementation uses `src/_internal.dart`, and so do the tests that reach
/// these types.
export 'src/_index.dart'
    hide
        CallProcessor,
        RpcCallerPipelineMixin,
        RpcEndpointPingExchange,
        RpcEndpointPingProtocol,
        RpcEndpointPingResult,
        RpcLongTimer,
        RpcResponderMethodBinding,
        RpcResponderMethodRegistry,
        RpcResponderPingHandler,
        RpcResponderPipelineMixin,
        RpcResponderStreamState,
        RpcResponderStreamStore,
        StreamProcessor;
