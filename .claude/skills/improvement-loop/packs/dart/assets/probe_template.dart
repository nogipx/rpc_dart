// Скелет пробы: одно число, флаг контроля, одинаковый стенд для обоих режимов.
//
// Запуск:  dart run tool/probe_<имя>.dart            — испытуемый случай
//          dart run tool/probe_<имя>.dart --control  — контроль: тот же стенд,
//                                                       убран предполагаемый механизм
// Печатает одну строку `metric=<число>` — её и цитирует запись раунда.
// Проба лежит там, где сказано в config.md («Пробы»), и не попадает в git.

import 'dart:io';

Future<void> main(List<String> args) async {
  final control = args.contains('--control');
  final scales = [1, 4, 16]; // три масштаба: удельное значение читается по кривой

  for (final scale in scales) {
    final before = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();

    // 1. Поднять стенд. Стороны — с РАЗНЫМИ объектами конфигурации.
    //    Никаких общих политик между атакующим и жертвой.
    // 2. Прогнать нагрузку `scale` единиц. При `control` — тот же объём и тот же
    //    путь, но без предполагаемого механизма (или с выключенным фиксом).
    // 3. Дождаться полки: измерять дельту за интервал, а не одно число.

    await Future<void>.delayed(Duration.zero); // заменить на нагрузку

    sw.stop();
    final after = ProcessInfo.currentRss;
    final perUnit = (after - before) / scale;
    stdout.writeln('scale=$scale control=$control '
        'rss_delta=${after - before} per_unit=${perUnit.toStringAsFixed(1)} '
        'ms=${sw.elapsedMilliseconds}');
  }

  // Число, которое идёт в запись раунда, — одно и названо по имени.
  stdout.writeln('metric=<заполнить>');
}
