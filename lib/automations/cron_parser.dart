/// Lightweight, pure-Dart standard 5-field Cron parser (`min hour dom month dow`)
/// with support for `*`, `*/n`, `a-b`, `a-b/n`, comma lists, and common macros
/// (`@hourly`, `@daily`, `@weekly`).
class CronSchedule {
  CronSchedule._({
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
  });

  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> daysOfMonth;
  final Set<int> months;
  final Set<int> daysOfWeek; // 0 = Sunday .. 6 = Saturday

  static CronSchedule? tryParse(String expression) {
    var trimmed = expression.trim();
    if (trimmed.isEmpty) return null;
    trimmed = switch (trimmed.toLowerCase()) {
      '@hourly' => '0 * * * *',
      '@daily' || '@midnight' => '0 0 * * *',
      '@weekly' => '0 0 * * 0',
      '@monthly' => '0 0 1 * *',
      _ => trimmed,
    };
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length != 5) return null;

    final min = _parseField(parts[0], 0, 59);
    final hr = _parseField(parts[1], 0, 23);
    final dom = _parseField(parts[2], 1, 31);
    final mon = _parseField(parts[3], 1, 12);
    final dow = _parseField(parts[4], 0, 7, wrapSevenToZero: true);
    if (min == null || hr == null || dom == null || mon == null || dow == null) {
      return null;
    }
    return CronSchedule._(
      minutes: min,
      hours: hr,
      daysOfMonth: dom,
      months: mon,
      daysOfWeek: dow,
    );
  }

  static Set<int>? _parseField(
    String raw,
    int min,
    int max, {
    bool wrapSevenToZero = false,
  }) {
    final result = <int>{};
    for (final segment in raw.split(',')) {
      final seg = segment.trim();
      if (seg.isEmpty) return null;
      final slashParts = seg.split('/');
      if (slashParts.length > 2) return null;
      final step = slashParts.length == 2 ? int.tryParse(slashParts[1]) : 1;
      if (step == null || step <= 0) return null;

      final rangePart = slashParts[0];
      int start;
      int end;
      if (rangePart == '*') {
        start = min;
        end = wrapSevenToZero ? 6 : max;
      } else if (rangePart.contains('-')) {
        final bounds = rangePart.split('-');
        if (bounds.length != 2) return null;
        final a = int.tryParse(bounds[0]);
        final b = int.tryParse(bounds[1]);
        if (a == null || b == null || a < min || b > max || a > b) return null;
        start = a;
        end = b;
      } else {
        final val = int.tryParse(rangePart);
        if (val == null || val < min || val > max) return null;
        start = val;
        end = slashParts.length == 2 ? (wrapSevenToZero ? 6 : max) : val;
      }
      for (var v = start; v <= end; v += step) {
        result.add(wrapSevenToZero && v == 7 ? 0 : v);
      }
    }
    return result.isEmpty ? null : result;
  }

  bool matches(DateTime dt) {
    final dow = dt.weekday % 7; // DateTime.sunday == 7 -> 0
    return minutes.contains(dt.minute) &&
        hours.contains(dt.hour) &&
        daysOfMonth.contains(dt.day) &&
        months.contains(dt.month) &&
        daysOfWeek.contains(dow);
  }

  /// Finds the next matching [DateTime] strictly after [from] (up to 1 year).
  DateTime? nextAfter(DateTime from) {
    var cursor = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
    ).add(const Duration(minutes: 1));
    final limit = cursor.add(const Duration(days: 366));
    while (cursor.isBefore(limit)) {
      if (!months.contains(cursor.month)) {
        cursor = DateTime(cursor.year, cursor.month + 1, 1);
        continue;
      }
      if (!daysOfMonth.contains(cursor.day) ||
          !daysOfWeek.contains(cursor.weekday % 7)) {
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
        continue;
      }
      if (!hours.contains(cursor.hour)) {
        cursor = DateTime(cursor.year, cursor.month, cursor.day, cursor.hour + 1);
        continue;
      }
      if (minutes.contains(cursor.minute)) {
        return cursor;
      }
      cursor = cursor.add(const Duration(minutes: 1));
    }
    return null;
  }
}
