// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Client-side library for rpc_dart_log.
///
/// Import this in your Flutter/Dart app to stream logs to a logview collector:
///
/// ```dart
/// import 'package:rpc_dart_log/rpc_dart_log.dart';
///
/// final controller = LogController(
///   outputs: [
///     ConsoleOutput(),
///     LogviewOutput(
///       uri: Uri.parse('ws://192.168.1.10:9500'),
///       device: DeviceInfo(name: 'iPhone 15', app: 'MyApp'),
///     ),
///   ],
/// );
/// ```
library;

export 'src/protocol.dart' show DeviceInfo;
export 'src/logview_output.dart' show LogviewOutput;
