import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every language file carries every key of the history and detail screens, with
/// the same placeholders, so no screen falls back to English text by accident.
const _keys = [
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

Map<String, dynamic> _load(String lang) =>
    jsonDecode(File('assets/i18n/$lang.json').readAsStringSync())
        as Map<String, dynamic>;

Set<String> _placeholders(String text) =>
    RegExp(r'\{[a-z]+\}').allMatches(text).map((m) => m.group(0)!).toSet();

void main() {
  final languages = Directory('assets/i18n')
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
      .toList()
    ..sort();

  test('the app ships 17 languages and all of them are checked', () {
    expect(languages, hasLength(17));
  });

  final english = _load('en');

  for (final lang in languages) {
    test('$lang has every history and detail string with the same placeholders',
        () {
      final data = _load(lang);
      for (final key in _keys) {
        expect(data[key], isA<String>(), reason: '$lang is missing $key');
        expect((data[key] as String).trim(), isNotEmpty,
            reason: '$lang has an empty $key');
        expect(_placeholders(data[key] as String),
            _placeholders(english[key] as String),
            reason: '$lang/$key placeholders differ from English');
      }
    });
  }

  test('Russian is translated, not copied from English', () {
    final ru = _load('ru');
    for (final key in _keys) {
      if (const {'txDetailHash', 'txRowSwap'}.contains(key)) continue;
      expect(ru[key], isNot(english[key]), reason: 'ru/$key is still English');
    }
  });
}
