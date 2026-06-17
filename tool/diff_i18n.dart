import 'dart:io';
import 'dart:convert';

void main() {
  final enFile = File('assets/i18n/en.json');
  final ruFile = File('assets/i18n/ru.json');
  final esFile = File('assets/i18n/es.json');

  final en = jsonDecode(enFile.readAsStringSync()) as Map<String, dynamic>;
  final ru = jsonDecode(ruFile.readAsStringSync()) as Map<String, dynamic>;
  final es = jsonDecode(esFile.readAsStringSync()) as Map<String, dynamic>;

  final enKeys = en.keys.toSet();
  final ruKeys = ru.keys.toSet();
  final esKeys = es.keys.toSet();

  print('Keys only in RU (12 expected):');
  for (final k in ruKeys.difference(enKeys)) {
    print('  "$k": "${ru[k]}"');
  }

  print('\nKeys only in EN (not in RU):');
  for (final k in enKeys.difference(ruKeys)) {
    print('  "$k": "${en[k]}"');
  }

  print('\nKeys in EN but missing in ES (36 expected):');
  for (final k in enKeys.difference(esKeys)) {
    print('  "$k": "${en[k]}"');
  }
}
