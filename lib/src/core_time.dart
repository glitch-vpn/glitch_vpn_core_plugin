/// The core's `ts` (an RFC 3339 string with an offset) as a UTC [DateTime];
/// the arrival time, in UTC, when a payload carries none, a non-string, or a
/// stamp without an offset, which would otherwise read as local time.
DateTime coreTime(Object? ts) {
  final parsed = ts is String ? DateTime.tryParse(ts) : null;
  if (parsed == null || !parsed.isUtc) return DateTime.now().toUtc();
  return parsed.toUtc();
}
