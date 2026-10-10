import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/risk_engine.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';
import 'package:ibiti_guardian/services/security/monitoring_service.dart';
import 'package:ibiti_guardian/services/security/monitoring_state_service.dart';

const _wallet = '0x1111111111111111111111111111111111111111';
const _token = '0x2222222222222222222222222222222222222222';
const _spender = '0x3333333333333333333333333333333333333333';
String _key(int chain) => '${chain}_${_spender}_$_token';
final _last = DateTime.utc(2026, 10, 9);

class _Source implements ApprovalSource {
  final calls = <int>[];
  final failed = <int>{};
  final rows = <int, List<ApprovalData>>{};
  @override
  Future<List<ApprovalData>> fetch(String wallet,
      {required int chainId, String? targetTokenAddress}) async {
    calls.add(chainId);
    if (failed.contains(chainId)) {
      throw const ApprovalSourceException('http_401');
    }
    return rows[chainId] ?? [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Source source;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'monitoring_last_scan_time': _last.toIso8601String(),
      'monitoring_last_risks': jsonEncode({
        _wallet: [_key(1), _key(56)]
      }),
    });
    await MonitoringStateService.instance.init();
    source = _Source();
    ApprovalScanService.sourceOverride = source;
    AnkrConfigService.instance.setKeyForTest('');
    ApprovalScanService.lastRiskScore = 17;
    ApprovalScanService.hasRiskyApprovals = true;
    ApprovalScanService.lastScannedApprovals = [];
    ApprovalScanService.lastScanTime = _last;
  });
  tearDown(() {
    ApprovalScanService.sourceOverride = null;
    ApprovalScanService.lastRiskScore = null;
    ApprovalScanService.hasRiskyApprovals = false;
    ApprovalScanService.lastScannedApprovals = [];
    ApprovalScanService.lastScanTime = null;
    AnkrConfigService.instance.setKeyForTest('');
  });
  test('failed scan preserves dashboard score and last successful time',
      () async {
    source.failed.add(56);
    await expectLater(
        ApprovalScanService.scan(_wallet, chainId: 56), throwsA(anything));
    expect(ApprovalScanService.lastRiskScore, 17);
    expect(ApprovalScanService.hasRiskyApprovals, true);
    expect(ApprovalScanService.lastScanTime, _last);
  });
  test('background and token-only scans do not overwrite user dashboard',
      () async {
    await ApprovalScanService.scan(_wallet, chainId: 1, publishResult: false);
    await ApprovalScanService.scan(_wallet,
        chainId: 56, targetTokenAddress: _token);
    expect(ApprovalScanService.lastRiskScore, 17);
    expect(ApprovalScanService.hasRiskyApprovals, true);
    expect(ApprovalScanService.lastScanTime, _last);
  });
  test('complete UI scan still evaluates through existing RiskEngine',
      () async {
    source.rows[56] = [
      ApprovalData(
          chainId: 56,
          token: _token,
          spenderAddress: _spender,
          spender: _spender,
          allowance: RiskEngine.maxUint256,
          walletAddress: _wallet)
    ];
    final rows = await ApprovalScanService.scan(_wallet, chainId: 56);
    expect(rows.single.assessment.shouldRevoke, true);
    expect(ApprovalScanService.hasRiskyApprovals, true);
    expect(ApprovalScanService.lastScannedApprovals, rows);
    expect(ApprovalScanService.lastScanTime, isNot(_last));
  });
  test('all failed monitoring chains retain every old risk', () async {
    source.failed.addAll([1, 56]);
    expect(
        await MonitoringService.instance.checkWalletForTest(_wallet, [1, 56]),
        false);
    final state = MonitoringStateService.instance;
    expect(state.isNewRisk(_wallet, _spender, _token, 1), false);
    expect(state.isNewRisk(_wallet, _spender, _token, 56), false);
    expect(state.lastScanTime, _last);
    expect(ApprovalScanService.lastRiskScore, 17);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('monitoring_last_risks')!)[_wallet],
        containsAll([_key(1), _key(56)]));
  });
  test('partial success removes only risks of a successfully checked chain',
      () async {
    source.failed.add(1);
    expect(
        await MonitoringService.instance.checkWalletForTest(_wallet, [1, 56]),
        false);
    final state = MonitoringStateService.instance;
    expect(state.isNewRisk(_wallet, _spender, _token, 1), false);
    expect(state.isNewRisk(_wallet, _spender, _token, 56), true);
    expect(state.lastScanTime, _last);
  });
  test('complete monitoring result can replace all checked chain risks',
      () async {
    expect(
        await MonitoringService.instance.checkWalletForTest(_wallet, [1, 56]),
        true);
    expect(
        MonitoringStateService.instance.isNewRisk(_wallet, _spender, _token, 1),
        true);
    expect(
        MonitoringStateService.instance
            .isNewRisk(_wallet, _spender, _token, 56),
        true);
    expect(ApprovalScanService.lastScanTime, _last);
  });
  test('scheduling/retry timestamp does not fabricate successful scan',
      () async {
    await MonitoringStateService.instance
        .updateNextScanTime(DateTime.utc(2026, 10, 11));
    expect(MonitoringStateService.instance.lastScanTime, _last);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getString('monitoring_last_scan_time'), _last.toIso8601String());
  });
}
