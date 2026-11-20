// MarketPolicyGate («Подготовить покупку» from a signal, and the automation
// queue) with the AI mode names the user sees: «Советник» / «Ручной» /
// «Автономный» (EN Advisor / Manual / Autonomous).
//
// Run: flutter test test/services/market/market_policy_gate_mode_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/market_policy_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';

const _sol = MarketAsset(
  id: 'solana',
  symbol: 'SOL',
  name: 'Solana',
  imageUrl: '',
  price: 100,
  change24h: 1,
  marketCap: 1000000000,
  volume: 50000000,
  rank: 5,
  sparkline: [],
  high24h: 105,
  low24h: 98,
  change7d: 2,
  change30d: 5,
  networkGroup: 'Solana',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: _owner);
    AuditLogService.instance.clear();
  });

  test('«Советник»: blocked by the mode, explained with the new names', () {
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(mode: AiMode.manual),
    );
    final r = MarketPolicyGate.instance.checkSwap(_sol);

    expect(r.isAllowed, isFalse);
    expect(r.verdict, MarketGateVerdict.blockedByMode);
    expect(r.reason, contains('Advisor mode'));
    expect(r.reason, contains('only advises'));

    final prompt = r.aiExplanationPrompt!;
    expect(prompt, contains('«Советник» (Advisor)'));
    expect(prompt, contains('Do NOT execute or prepare a trade'));
    // How to let the AI act: «Ручной» prepares (PIN), «Автономный» acts.
    expect(prompt, contains('«Ручной» (Manual'));
    expect(prompt, contains('«Автономный» (Autonomous)'));

    for (final text in [r.reason!, prompt]) {
      for (final old in [
        'Guarded',
        'Full Autonomy',
        'Manual mode',
        'mode is Manual',
      ]) {
        expect(text, isNot(contains(old)), reason: old);
      }
    }
  });

  test('«Ручной»: the window may open; the audit names the mode «Manual»',
      () {
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(mode: AiMode.guarded),
    );
    final r = MarketPolicyGate.instance.checkSwap(_sol);

    expect(r.isAllowed, isTrue);
    final entry = AuditLogService.instance.entries.first;
    expect(entry.actionLabel, 'MARKET_SWAP_ALLOWED');
    expect(entry.summary, contains('mode: Manual'));
    expect(entry.summary, isNot(contains('guarded')));
  });

  test('«Автономный»: the audit names the mode «Autonomous»', () {
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(mode: AiMode.fullAutonomy),
    );
    final r = MarketPolicyGate.instance.checkSwap(_sol);

    expect(r.isAllowed, isTrue);
    final entry = AuditLogService.instance.entries.first;
    expect(entry.summary, contains('mode: Autonomous'));
    expect(entry.summary, isNot(contains('fullAutonomy')));
  });
}
