String fmtTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == n.year && d.month == n.month && d.day == n.day) return hm;
  return '${two(d.day)}.${two(d.month)} $hm';
}
