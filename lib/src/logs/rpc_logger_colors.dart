// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// ANSI цвета для вывода в консоль
///
/// Предоставляет константы для цветного форматирования текста в консоли
/// с использованием ANSI escape-последовательностей.
///
/// Пример использования:
/// ```dart
/// print('${AnsiColor.green.code}Текст зеленого цвета${AnsiColor.reset.code}');
/// print('${AnsiColor.bold.code}${AnsiColor.red.code}Жирный красный${AnsiColor.reset.code}');
/// ```
enum AnsiColor {
  // ============================================================================
  // Управляющие последовательности
  // ============================================================================
  reset('\x1B[0m'),
  bold('\x1B[1m'),
  italic('\x1B[3m'),
  underline('\x1B[4m'),
  strikethrough('\x1B[9m'),

  // ============================================================================
  // Обычные цвета
  // ============================================================================
  black('\x1B[0;30m'),
  red('\x1B[0;31m'),
  green('\x1B[0;32m'),
  yellow('\x1B[0;33m'),
  blue('\x1B[0;34m'),
  magenta('\x1B[0;35m'),
  cyan('\x1B[0;36m'),
  white('\x1B[0;37m'),

  // ============================================================================
  // Жирные цвета
  // ============================================================================
  boldBlack('\x1B[1;30m'),
  boldRed('\x1B[1;31m'),
  boldGreen('\x1B[1;32m'),
  boldYellow('\x1B[1;33m'),
  boldBlue('\x1B[1;34m'),
  boldMagenta('\x1B[1;35m'),
  boldCyan('\x1B[1;36m'),
  boldWhite('\x1B[1;37m'),

  // ============================================================================
  // Подчеркнутые цвета
  // ============================================================================
  underlineBlack('\x1B[4;30m'),
  underlineRed('\x1B[4;31m'),
  underlineGreen('\x1B[4;32m'),
  underlineYellow('\x1B[4;33m'),
  underlineBlue('\x1B[4;34m'),
  underlineMagenta('\x1B[4;35m'),
  underlineCyan('\x1B[4;36m'),
  underlineWhite('\x1B[4;37m'),

  // ============================================================================
  // Фоновые цвета
  // ============================================================================
  bgBlack('\x1B[40m'),
  bgRed('\x1B[41m'),
  bgGreen('\x1B[42m'),
  bgYellow('\x1B[43m'),
  bgBlue('\x1B[44m'),
  bgMagenta('\x1B[45m'),
  bgCyan('\x1B[46m'),
  bgWhite('\x1B[47m'),

  // ============================================================================
  // Яркие цвета (High Intensity)
  // ============================================================================
  brightBlack('\x1B[0;90m'),
  brightRed('\x1B[0;91m'),
  brightGreen('\x1B[0;92m'),
  brightYellow('\x1B[0;93m'),
  brightBlue('\x1B[0;94m'),
  brightMagenta('\x1B[0;95m'),
  brightCyan('\x1B[0;96m'),
  brightWhite('\x1B[0;97m'),

  // ============================================================================
  // Жирные яркие цвета (Bold High Intensity)
  // ============================================================================
  boldBrightBlack('\x1B[1;90m'),
  boldBrightRed('\x1B[1;91m'),
  boldBrightGreen('\x1B[1;92m'),
  boldBrightYellow('\x1B[1;93m'),
  boldBrightBlue('\x1B[1;94m'),
  boldBrightMagenta('\x1B[1;95m'),
  boldBrightCyan('\x1B[1;96m'),
  boldBrightWhite('\x1B[1;97m'),

  // ============================================================================
  // Яркие фоновые цвета (High Intensity Background)
  // ============================================================================
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

  /// Комбинирует текущий цвет с другим стилем
  ///
  /// Пример:
  /// ```dart
  /// final redBold = AnsiColor.red.combine(AnsiColor.bold);
  /// print('${redBold}Красный жирный текст${AnsiColor.reset.code}');
  /// ```
  String combine(AnsiColor other) => code + other.code;

  /// Применяет цвет к тексту и автоматически сбрасывает
  ///
  /// Пример:
  /// ```dart
  /// print(AnsiColor.green.wrap('Зеленый текст'));
  /// ```
  String wrap(String text) => '$code$text${AnsiColor.reset.code}';
}

/// Настройки цветов для разных уровней логирования
class RpcLoggerColors {
  /// Цвет для логов уровня internal
  final AnsiColor internal;

  /// Цвет для логов уровня debug
  final AnsiColor debug;

  /// Цвет для логов уровня info
  final AnsiColor info;

  /// Цвет для логов уровня warning
  final AnsiColor warning;

  /// Цвет для логов уровня error
  final AnsiColor error;

  /// Цвет для логов уровня critical
  final AnsiColor critical;

  /// Создаёт настройки цветов с указанными значениями
  const RpcLoggerColors({
    this.internal = AnsiColor.brightBlack,
    this.debug = AnsiColor.cyan,
    this.info = AnsiColor.green,
    this.warning = AnsiColor.yellow,
    this.error = AnsiColor.red,
    this.critical = AnsiColor.brightRed,
  });

  /// Создаёт настройки с одним цветом для всех уровней
  const RpcLoggerColors.singleColor(AnsiColor color)
      : internal = color,
        debug = color,
        info = color,
        warning = color,
        error = color,
        critical = color;

  /// Яркая цветовая схема
  const RpcLoggerColors.bright()
      : internal = AnsiColor.brightBlack,
        debug = AnsiColor.brightCyan,
        info = AnsiColor.brightGreen,
        warning = AnsiColor.brightYellow,
        error = AnsiColor.brightRed,
        critical = AnsiColor.boldBrightRed;

  /// Жирная цветовая схема
  const RpcLoggerColors.bold()
      : internal = AnsiColor.boldBlack,
        debug = AnsiColor.boldCyan,
        info = AnsiColor.boldGreen,
        warning = AnsiColor.boldYellow,
        error = AnsiColor.boldRed,
        critical = AnsiColor.boldBrightRed;

  /// Получает цвет для указанного уровня логирования
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
