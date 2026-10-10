import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const _locales = [
  'ar',
  'de',
  'en',
  'es',
  'fr',
  'hi',
  'id',
  'it',
  'ja',
  'ko',
  'pl',
  'pt',
  'ru',
  'tr',
  'uk',
  'vi',
  'zh',
];
const _scanKeys = [
  'guardianSafeBtnOk',
  'guardianResCheckSafe',
  'guardianResCheckPanic',
  'guardianCheckedContracts',
  'guardianStatScanned',
];
const _historyKeys = [
  'txFilterAll',
  'txFilterSent',
  'txFilterReceived',
  'txFilterApprovals',
  'txFilterSwaps',
  'txRowSent',
  'txRowReceived',
  'txRowApproval',
  'txRowSwap',
  'txRowSwapped',
  'txRowTransaction',
  'txRowFunds',
  'txSubTo',
  'txSubFrom',
  'txSubSpender',
  'txSubViaContract',
  'txEmptyTitle',
  'txEmptyBody',
  'txEmptyFilteredTitle',
  'txEmptyFilteredBody',
  'txAgoNow',
  'txAgoMinutes',
  'txAgoHours',
  'txAgoDays',
  'txDetailTitle',
  'txDetailConfirmed',
  'txDetailFailed',
  'txDetailSold',
  'txDetailBought',
  'txDetailFrom',
  'txDetailTo',
  'txDetailNetwork',
  'txDetailTime',
  'txDetailFee',
  'txDetailToken',
  'txDetailContract',
  'txDetailHash',
  'txDetailOpenExplorer',
  'txDetailCopied',
];

Map<String, dynamic> _load(String locale) =>
    jsonDecode(File('assets/i18n/$locale.json').readAsStringSync())
        as Map<String, dynamic>;

List<String> _placeholders(String text) => RegExp(r'\{[a-zA-Z]+\}')
    .allMatches(text)
    .map((match) => match.group(0)!)
    .toList()
  ..sort();

void main() {
  final english = _load('en');
  for (final locale in _locales) {
    test('$locale has complete scan/history strings and matching placeholders',
        () {
      final raw = File('assets/i18n/$locale.json').readAsStringSync();
      final data = _load(locale);
      for (final key in [..._scanKeys, ..._historyKeys]) {
        final value = data[key];
        expect(value, isA<String>(), reason: '$locale/$key');
        expect((value as String).trim(), isNotEmpty, reason: '$locale/$key');
        expect(_placeholders(value), _placeholders(english[key] as String),
            reason: '$locale/$key');
        expect(RegExp('"$key"\\s*:').allMatches(raw).length, 1,
            reason: '$locale/$key must not be shadowed by a duplicate key');
      }
      expect(_placeholders(data['guardianCheckedContracts'] as String),
          ['{chain}', '{count}']);
    });
  }

  test('Russian scan copy counts approvals and makes no total safety promise',
      () {
    final data = _load('ru');
    expect(data['guardianCheckedContracts'],
        'Активных разрешений токенов: {count} (сеть {chain})');
    expect(data['guardianStatScanned'], 'Разрешения');
    expect(data['guardianSafeBtnOk'], 'Понятно');
    expect(data['guardianResCheckSafe'],
        'Проверены разрешения токенов в выбранной сети.');
  });

  test('English scan copy counts approvals and makes no total safety promise',
      () {
    expect(english['guardianCheckedContracts'],
        'Active token approvals: {count} on {chain}');
    expect(english['guardianStatScanned'], 'Approvals');
    expect(english['guardianSafeBtnOk'], 'Got it');
    expect(english['guardianResCheckSafe'],
        'Token approvals were checked on the selected network.');
  });
}
