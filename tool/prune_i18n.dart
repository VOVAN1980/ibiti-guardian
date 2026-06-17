import 'dart:io';
import 'dart:convert';

void main() {
  final dir = Directory('assets/i18n');
  final enFile = File('assets/i18n/en.json');
  final en = jsonDecode(enFile.readAsStringSync()) as Map<String, dynamic>;
  final tempEnKeys = en.keys.toSet();

  int totalPruned = 0;
  int fileCount = 0;

  for (var entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.json')) {
      final lang = entity.path.split(Platform.pathSeparator).last;
      if (lang == 'en.json' || lang == 'ru.json')
        continue; // RU is already matching

      final map = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      final keys = map.keys.toSet();

      final extra = keys.difference(tempEnKeys);
      if (extra.isNotEmpty) {
        for (final k in extra) {
          map.remove(k);
          totalPruned++;
        }
        const encoder = JsonEncoder.withIndent('  ');
        entity.writeAsStringSync('${encoder.convert(map)}\n');
      }
      fileCount++;
    }
  }

  print(
      'Pruned $totalPruned orphan keys across $fileCount files. All languages should now have exactly ${tempEnKeys.length} keys.');
}
