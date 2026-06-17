import 'dart:io';
import 'dart:convert';

void main() {
  final dir = Directory('assets/i18n');
  final enFile = File('assets/i18n/en.json');
  final ruFile = File('assets/i18n/ru.json');

  final en = jsonDecode(enFile.readAsStringSync()) as Map<String, dynamic>;
  final ru = jsonDecode(ruFile.readAsStringSync()) as Map<String, dynamic>;

  // 1. Missing in EN (only in RU)
  // Translate the 12 RU-only keys into English natively.
  final ruToEnMap = {
    'riskLabelSafe': 'Safe',
    'riskLabelCaution': 'Caution',
    'riskLabelDanger': 'Danger',
    'riskLabelCritical': 'Critical',
    'walletConnectionGuestSub': 'View-only mode without signing',
    'dashboardScanInfoSubtitle': 'Approvals and tokens',
    'dashboardScanInfoEmptySubtitle': 'No assets found',
    'dashboardShieldStatusSubtitle': 'Real-time protection',
    'dashboardWalletTapConnectSubtitle': 'No active connection',
    'dashboardWalletTapConnectHint': 'Tap to connect your wallet',
    'dashboardWalletTapDisconnectSubtitle': 'Connected via WalletConnect',
    'dashboardWalletTapDisconnectHint': 'Tap to disconnect',
  };

  for (final k in ru.keys) {
    if (!en.containsKey(k)) {
      en[k] = ruToEnMap[k] ?? ru[k]; // Fallback to ru if not mapped
    }
  }

  // 2. Missing in RU (only in EN) -> though we know it's 0, let's be safe.
  for (final k in en.keys) {
    if (!ru.containsKey(k)) {
      ru[k] = en[k];
    }
  }

  // Save unified EN and RU
  const encoder = JsonEncoder.withIndent('  ');
  enFile.writeAsStringSync('${encoder.convert(en)}\n');
  ruFile.writeAsStringSync('${encoder.convert(ru)}\n');

  print('EN and RU unified to ${en.keys.length} keys.');

  // 3. Sync the 15 other languages
  int fileCount = 0;
  for (var entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.json')) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == 'en.json' || name == 'ru.json') continue;

      final map = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      int added = 0;
      for (final k in en.keys) {
        if (!map.containsKey(k)) {
          map[k] = en[k]; // Use English as the clean standard fallback
          added++;
        }
      }

      entity.writeAsStringSync('${encoder.convert(map)}\n');
      print('Synced $name: added $added missing keys.');
      fileCount++;
    }
  }

  print(
      'Successfully synced $fileCount foreign languages. All 17 files now have the exact same keyset.');
}
