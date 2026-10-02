const sessionTransitions = <String, List<String>>{
  'Scheduled': ['Waiting', 'Missed', 'Cancelled'],
  'Waiting': ['In Progress', 'Missed', 'Cancelled'],
  'In Progress': ['Completed'],
  'Completed': ['Ready for Pickup'],
  'Ready for Pickup': ['Picked Up'],
  'Picked Up': [],
  'Missed': [],
  'Cancelled': [],
};
DateTime centerTime(DateTime utc) => utc.toUtc().add(const Duration(hours: 8));
String greeting(DateTime utc) {
  final h = centerTime(utc).hour;
  return h >= 5 && h < 12
      ? 'Good Morning!'
      : h >= 12 && h < 18
      ? 'Good Afternoon!'
      : 'Good Evening!';
}

String centerDay(DateTime utc) =>
    centerTime(utc).toIso8601String().substring(0, 10);
String centerDateTime(dynamic millis) {
  if (millis is! num) return '--';
  final d = centerTime(
    DateTime.fromMillisecondsSinceEpoch(millis.toInt(), isUtc: true),
  );
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class CareRecord {
  CareRecord(this.id, Map<String, dynamic> value) : data = Map.of(value);
  final String id;
  final Map<String, dynamic> data;
  String text(String key, [String fallback = '']) =>
      data[key]?.toString() ?? fallback;
  int number(String key, [int fallback = 0]) =>
      (data[key] as num?)?.toInt() ?? fallback;
}

Map<String, int> dashboardCounts(Iterable<CareRecord> sessions, DateTime utc) {
  final today = sessions
      .where(
        (s) =>
            s.text('day') == centerDay(utc) && s.text('status') != 'Cancelled',
      )
      .toList();
  return {
    'Total Patients Today': today
        .map((s) => s.text('patientId'))
        .toSet()
        .length,
    'Active Sessions': today
        .where((s) => s.text('status') == 'In Progress')
        .length,
    'Pending': today
        .where((s) => ['Scheduled', 'Waiting'].contains(s.text('status')))
        .length,
    'Completed': today
        .where(
          (s) => [
            'Completed',
            'Ready for Pickup',
            'Picked Up',
          ].contains(s.text('status')),
        )
        .length,
  };
}

void validateSchedule(
  Map<String, dynamic> value,
  Iterable<CareRecord> others,
  String id,
) {
  final start = value['startMs'] as int? ?? 0;
  final end = value['endMs'] as int? ?? 0;
  if (start <= 0 || end <= start || end - start > 12 * 3600000) {
    throw StateError('Choose an end time after start, within 12 hours.');
  }
  if (!['Batch A', 'Batch B', 'Batch C'].contains(value['batch']) ||
      (value['room'] ?? '').toString().trim().isEmpty) {
    throw StateError('Choose a batch and room.');
  }
  for (final s in others) {
    if (s.id == id || ['Cancelled', 'Missed'].contains(s.text('status'))) {
      continue;
    }
    if (s.number('startMs') < end &&
        s.number('endMs') > start &&
        (s.text('patientId') == value['patientId'] ||
            s.text('room').trim().toLowerCase().replaceAll(RegExp(r'\s+'),' ') == value['room'].toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'),' '))) {
      throw StateError('Patient or room overlaps an existing appointment.');
    }
  }
}
