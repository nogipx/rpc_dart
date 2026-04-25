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
  /// Resets all attributes.
  reset('\x1B[0m'),

  /// Bold text.
  bold('\x1B[1m'),

  /// Italic text.
  italic('\x1B[3m'),

  /// Underlined text.
  underline('\x1B[4m'),

  /// Strikethrough text.
  strikethrough('\x1B[9m'),

  // Standard colors.
  /// Standard black foreground.
  black('\x1B[0;30m'),

  /// Standard red foreground.
  red('\x1B[0;31m'),

  /// Standard green foreground.
  green('\x1B[0;32m'),

  /// Standard yellow foreground.
  yellow('\x1B[0;33m'),

  /// Standard blue foreground.
  blue('\x1B[0;34m'),

  /// Standard magenta foreground.
  magenta('\x1B[0;35m'),

  /// Standard cyan foreground.
  cyan('\x1B[0;36m'),

  /// Standard white foreground.
  white('\x1B[0;37m'),

  // Bold colors.
  /// Bold black foreground.
  boldBlack('\x1B[1;30m'),

  /// Bold red foreground.
  boldRed('\x1B[1;31m'),

  /// Bold green foreground.
  boldGreen('\x1B[1;32m'),

  /// Bold yellow foreground.
  boldYellow('\x1B[1;33m'),

  /// Bold blue foreground.
  boldBlue('\x1B[1;34m'),

  /// Bold magenta foreground.
  boldMagenta('\x1B[1;35m'),

  /// Bold cyan foreground.
  boldCyan('\x1B[1;36m'),

  /// Bold white foreground.
  boldWhite('\x1B[1;37m'),

  // Underlined colors.
  /// Underlined black foreground.
  underlineBlack('\x1B[4;30m'),

  /// Underlined red foreground.
  underlineRed('\x1B[4;31m'),

  /// Underlined green foreground.
  underlineGreen('\x1B[4;32m'),

  /// Underlined yellow foreground.
  underlineYellow('\x1B[4;33m'),

  /// Underlined blue foreground.
  underlineBlue('\x1B[4;34m'),

  /// Underlined magenta foreground.
  underlineMagenta('\x1B[4;35m'),

  /// Underlined cyan foreground.
  underlineCyan('\x1B[4;36m'),

  /// Underlined white foreground.
  underlineWhite('\x1B[4;37m'),

  // Background colors.
  /// Black background.
  bgBlack('\x1B[40m'),

  /// Red background.
  bgRed('\x1B[41m'),

  /// Green background.
  bgGreen('\x1B[42m'),

  /// Yellow background.
  bgYellow('\x1B[43m'),

  /// Blue background.
  bgBlue('\x1B[44m'),

  /// Magenta background.
  bgMagenta('\x1B[45m'),

  /// Cyan background.
  bgCyan('\x1B[46m'),

  /// White background.
  bgWhite('\x1B[47m'),

  // Bright (high intensity) colors.
  /// Bright black (dark gray) foreground.
  brightBlack('\x1B[0;90m'),

  /// Bright red foreground.
  brightRed('\x1B[0;91m'),

  /// Bright green foreground.
  brightGreen('\x1B[0;92m'),

  /// Bright yellow foreground.
  brightYellow('\x1B[0;93m'),

  /// Bright blue foreground.
  brightBlue('\x1B[0;94m'),

  /// Bright magenta foreground.
  brightMagenta('\x1B[0;95m'),

  /// Bright cyan foreground.
  brightCyan('\x1B[0;96m'),

  /// Bright white foreground.
  brightWhite('\x1B[0;97m'),

  // Bold bright (high intensity).
  /// Bold bright black foreground.
  boldBrightBlack('\x1B[1;90m'),

  /// Bold bright red foreground.
  boldBrightRed('\x1B[1;91m'),

  /// Bold bright green foreground.
  boldBrightGreen('\x1B[1;92m'),

  /// Bold bright yellow foreground.
  boldBrightYellow('\x1B[1;93m'),

  /// Bold bright blue foreground.
  boldBrightBlue('\x1B[1;94m'),

  /// Bold bright magenta foreground.
  boldBrightMagenta('\x1B[1;95m'),

  /// Bold bright cyan foreground.
  boldBrightCyan('\x1B[1;96m'),

  /// Bold bright white foreground.
  boldBrightWhite('\x1B[1;97m'),

  // Bright backgrounds.
  /// Bright black background.
  bgBrightBlack('\x1B[0;100m'),

  /// Bright red background.
  bgBrightRed('\x1B[0;101m'),

  /// Bright green background.
  bgBrightGreen('\x1B[0;102m'),

  /// Bright yellow background.
  bgBrightYellow('\x1B[0;103m'),

  /// Bright blue background.
  bgBrightBlue('\x1B[0;104m'),

  /// Bright magenta background.
  bgBrightMagenta('\x1B[0;105m'),

  /// Bright cyan background.
  bgBrightCyan('\x1B[0;106m'),

  /// Bright white background.
  bgBrightWhite('\x1B[0;107m');

  /// The raw ANSI escape code string.
  final String code;

  /// Creates an [AnsiColor] with the given escape [code].
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
