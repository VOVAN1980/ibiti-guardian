// A sandbox-approved automated transaction goes through AiActionGate BEFORE
// the daily budget is reserved (C2), and its reservation is committed from
// the executor's own receipt wait (not the shared TxStatusPoller, C7).
//
// Run: flutter test test/services/execution/sandbox_automation_gate_test.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';
const _trusted = '0x1111111111111111111111111111111111111111';
const _stranger = '0x3333333333333333333333333333333333333333';
const _usdt = '0x55d398326f99059fF775485246999027B3197955';

TransactionRequest _send({String to = _trusted, double amount = 10}) =>
    TransactionRequest(
      type: TransactionType.send,
      fromAddress: _owner,
      toAddress: to,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      amount: amount,
      rawAmount: BigInt.from(amount) * BigInt.from(10).pow(18),
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: const IntentData(
        type: IntentType.sendAsset,
        rawInput: '_AUTO_ test',
        sourceTrigger: 'rule_1',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = GuardianExecutionController.instance;
  final gate = AiActionGate.instance;
  final demoted = AssistantResponse.info('demoted to preview');

  late int dispatches;
  late int cards;
  late bool cardAnswer;
  late List<String> notifications;

  void useSettings({AiMode mode = AiMode.fullAutonomy, bool pin = true}) {
    AiControlService.instance.setSettingsForTest(AiControlSettings(
      mode: mode,
      dailyLimit: 1000,
      aiPinConfirm: pin,
    ));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: _owner);
    await EPKPolicyManager.instance.resumeProtection();
    await PolicyProfileStore.instance.addTrustedAddress(_trusted);
    DelegationController.instance.resetUsageForTest();
    TxUsdValuer.priceOverrideForTest = (_) => 1.0;
    useSettings();

    dispatches = 0;
    cards = 0;
    cardAnswer = true;
    notifications = [];

    gate.resetForTest();
    gate.foregroundOverride = () => true;
    gate.confirmUiOverride = (s) async {
      cards++;
      // C2: nothing is reserved while the card is open.
      expect(DelegationController.instance.reservedUsd, 0);
      return cardAnswer;
    };
    gate.notifyOverride = (title, body) => notifications.add(title);

    AiOnchainExecutor.instance.resetForTest();
    AiOnchainExecutor.instance.receiptWaiterOverride = (tx, hash) async => true;
    controller.automationDispatchOverride = (tx, path) async {
      dispatches++;
      return const AssistantResponse(
        message: 'sent',
        type: ResponseType.action,
        detail: '0xfeed',
      );
    };
  });

  tearDown(() async {
    controller.automationDispatchOverride = null;
    AiOnchainExecutor.instance.resetForTest();
    gate.resetForTest();
    TxUsdValuer.priceOverrideForTest = null;
    await PolicyProfileStore.instance.removeTrustedAddress(_trusted);
  });

  test('PIN on + declined card: no dispatch, no reservation, a preview instead',
      () async {
    cardAnswer = false;
    final r = await controller.runApprovedAutomationForTest(
        _send(), ExecutionPath.localProtected,
        demote: () => demoted);
    expect(identical(r, demoted), isTrue);
    expect(cards, 1);
    expect(dispatches, 0);
    expect(DelegationController.instance.reservedUsd, 0);
    expect(notifications, isEmpty);
  });

  test('PIN on + confirmed: dispatched once, budget committed on the receipt',
      () async {
    final r = await controller.runApprovedAutomationForTest(
        _send(), ExecutionPath.localProtected,
        demote: () => demoted);
    expect(r.type, ResponseType.action);
    expect(dispatches, 1);
    expect(notifications, hasLength(1));
    await Future<void>.delayed(Duration.zero);
    expect(DelegationController.instance.usedTodayUsd, 10);
    expect(DelegationController.instance.reservedUsd, 0);
  });

  test('PIN off + trusted recipient: no card, dispatched, notification',
      () async {
    useSettings(pin: false);
    final r = await controller.runApprovedAutomationForTest(
        _send(), ExecutionPath.localProtected,
        demote: () => demoted);
    expect(r.type, ResponseType.action);
    expect(cards, 0);
    expect(dispatches, 1);
    expect(notifications, hasLength(1));
  });

  test('PIN off + new address: the card + PIN are asked first', () async {
    useSettings(pin: false);
    cardAnswer = false;
    final r = await controller.runApprovedAutomationForTest(
        _send(to: _stranger), ExecutionPath.localProtected,
        demote: () => demoted);
    expect(identical(r, demoted), isTrue);
    expect(cards, 1);
    expect(dispatches, 0);
  });

  test('EPK paused: blocked, nothing dispatched', () async {
    useSettings(pin: false);
    await EPKPolicyManager.instance.emergencyPause();
    final r = await controller.runApprovedAutomationForTest(
        _send(), ExecutionPath.localProtected,
        demote: () => demoted);
    expect(r.type, ResponseType.error);
    expect(dispatches, 0);
  });

  test('over the daily limit: blocked by the gate, nothing reserved',
      () async {
    final r = await controller.runApprovedAutomationForTest(
        _send(amount: 5000), ExecutionPath.localProtected,
        demote: () => demoted);
    expect(r.type, ResponseType.error);
    expect(cards, 0);
    expect(dispatches, 0);
    expect(DelegationController.instance.reservedUsd, 0);
  });
}
