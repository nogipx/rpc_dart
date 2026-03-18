// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// ANSI colors for console output.
///
/// Provides constants for color formatting using ANSI escape sequences.
///
/// Example:
/// ```dart
/// print('${AnsiColor.green.code}Green text${AnsiColor.reset.code}');
/// print('${AnsiColor.bold.code}${AnsiColor.red.code}Bold red${AnsiColor.reset.code}');
/// ```
enum AnsiColor {
  // Control sequences.
  reset('\x1B[0m'),
  bold('\x1B[1m'),
  italic('\x1B[3m'),
  underline('\x1B[4m'),
  strikethrough('\x1B[9m'),

  // Standard colors.
  black('\x1B[0;30m'),
  red('\x1B[0;31m'),
  green('\x1B[0;32m'),
  yellow('\x1B[0;33m'),
  blue('\x1B[0;34m'),
  magenta('\x1B[0;35m'),
  cyan('\x1B[0;36m'),
  white('\x1B[0;37m'),

  // Bold colors.
  boldBlack('\x1B[1;30m'),
  boldRed('\x1B[1;31m'),
  boldGreen('\x1B[1;32m'),
  boldYellow('\x1B[1;33m'),
  boldBlue('\x1B[1;34m'),
  boldMagenta('\x1B[1;35m'),
  boldCyan('\x1B[1;36m'),
  boldWhite('\x1B[1;37m'),

  // Underlined colors.
  underlineBlack('\x1B[4;30m'),
  underlineRed('\x1B[4;31m'),
  underlineGreen('\x1B[4;32m'),
  underlineYellow('\x1B[4;33m'),
  underlineBlue('\x1B[4;34m'),
  underlineMagenta('\x1B[4;35m'),
  underlineCyan('\x1B[4;36m'),
  underlineWhite('\x1B[4;37m'),

  // Background colors.
  bgBlack('\x1B[40m'),
  bgRed('\x1B[41m'),
  bgGreen('\x1B[42m'),
  bgYellow('\x1B[43m'),
  bgBlue('\x1B[44m'),
  bgMagenta('\x1B[45m'),
  bgCyan('\x1B[46m'),
  bgWhite('\x1B[47m'),

  // Bright (high intensity) colors.
  brightBlack('\x1B[0;90m'),
  brightRed('\x1B[0;91m'),
  brightGreen('\x1B[0;92m'),
  brightYellow('\x1B[0;93m'),
  brightBlue('\x1B[0;94m'),
  brightMagenta('\x1B[0;95m'),
  brightCyan('\x1B[0;96m'),
  brightWhite('\x1B[0;97m'),

  // Bold bright (high intensity).
  boldBrightBlack('\x1B[1;90m'),
  boldBrightRed('\x1B[1;91m'),
  boldBrightGreen('\x1B[1;92m'),
  boldBrightYellow('\x1B[1;93m'),
  boldBrightBlue('\x1B[1;94m'),
  boldBrightMagenta('\x1B[1;95m'),
  boldBrightCyan('\x1B[1;96m'),
  boldBrightWhite('\x1B[1;97m'),

  // Bright backgrounds.
  bgBrightBlack('\x1B[0;100m'),
  bgBrightRed('\x1B[0;101m'),
  bgBrightGreen('\x1B[0;102m'),
  bgBrightYellow('\x1B[0;103m'),
  bgBrightBlue('\x1B[0;104m'),
  bgBrightMagenta('\x1B[0;105m'),
  bgBrightCyan('\x1B[0;106m'),
  bgBrightWhite('\x1B[0;107m');

  final String code;
  const AnsiColor(this.code);

  /// Combines the current color with another style.
  String combine(AnsiColor other) => code + other.code;

  /// Wraps text with the color and resets it automatically.
  String wrap(String text) => '$code$text${AnsiColor.reset.code}';
}

/// Color configuration for logging levels.
class RpcLoggerColors {
  /// Color for internal logs.
  final AnsiColor internal;

  /// Color for debug logs.
  final AnsiColor debug;

  /// Color for info logs.
  final AnsiColor info;

  /// Color for warning logs.
  final AnsiColor warning;

  /// Color for error logs.
  final AnsiColor error;

  /// Color for critical logs.
  final AnsiColor critical;

  /// Creates a palette with explicit values.
  const RpcLoggerColors({
    this.internal = AnsiColor.brightBlack,
    this.debug = AnsiColor.cyan,
    this.info = AnsiColor.green,
    this.warning = AnsiColor.yellow,
    this.error = AnsiColor.red,
    this.critical = AnsiColor.brightRed,
  });

  /// Creates a palette using one color for every level.
  const RpcLoggerColors.singleColor(AnsiColor color)
      : internal = color,
        debug = color,
        info = color,
        warning = color,
        error = color,
        critical = color;

  /// Bright color scheme.
  const RpcLoggerColors.bright()
      : internal = AnsiColor.brightBlack,
        debug = AnsiColor.brightCyan,
        info = AnsiColor.brightGreen,
        warning = AnsiColor.brightYellow,
        error = AnsiColor.brightRed,
        critical = AnsiColor.boldBrightRed;

  /// Bold color scheme.
  const RpcLoggerColors.bold()
      : internal = AnsiColor.boldBlack,
        debug = AnsiColor.boldCyan,
        info = AnsiColor.boldGreen,
        warning = AnsiColor.boldYellow,
        error = AnsiColor.boldRed,
        critical = AnsiColor.boldBrightRed;

  /// Returns the color for a logging level.
  AnsiColor colorForLevel(RpcLoggerLevel level) {
    switch (level) {
      case RpcLoggerLevel.internal:
        return internal;
      case RpcLoggerLevel.debug:
        return debug;
      case RpcLoggerLevel.info:
        return info;
      case RpcLoggerLevel.warning:
        return warning;
      case RpcLoggerLevel.error:
        return error;
      case RpcLoggerLevel.critical:
        return critical;
      default:
        return AnsiColor.white;
    }
  }
}
