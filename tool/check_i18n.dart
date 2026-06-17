import 'dart:convert';
import 'dart:io';

void main() {
  final dir = Directory('assets/i18n');
  if (!dir.existsSync()) {
    print('No i18n dir');
    return;
  }

  final enFile = File('assets/i18n/en.json');
  if (!enFile.existsSync()) {
    print('No en.json');
    return;
  }

  final Map<String, dynamic> enMap = jsonDecode(enFile.readAsStringSync());
  final enKeys = enMap.keys.toSet();
  print('EN keys: ${enKeys.length}');

  for (var entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.json')) {
      final lang = entity.path.split(Platform.pathSeparator).last;
      if (lang == 'en.json') continue;

      final Map<String, dynamic> langMap =
          jsonDecode(entity.readAsStringSync());
      final langKeys = langMap.keys.toSet();

      final missing = enKeys.difference(langKeys);
      final extra = langKeys.difference(enKeys);

      print(
          '$lang -> keys: ${langKeys.length}, missing from EN: ${missing.length}, extra over EN: ${extra.length}');
      if (missing.isNotEmpty && missing.length < 5) {
        print('  Missing: $missing');
      }
    }
  }
}
