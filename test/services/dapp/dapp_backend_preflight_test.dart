import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_wallet_backend.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'dapp_verified_receive_test.dart' as fixture;

class PreflightRpc extends DappRpc {
  final fixture.ReceiveRpc receiver;
  PreflightRpc(this.receiver);
  @override
  Future<dynamic> call(int chain, String method, List<dynamic> params) async {
    if (method == 'eth_call' && params.last == 'latest') return '0x';
    if (method == 'eth_estimateGas') return '0xa0000';
    if (method == 'eth_getBalance') return '0xffffffffff';
    return receiver.call(chain, method, params);
  }
}

// Only the vault/session availability is replaced. Production preparation,
// code proofs, policy/composite, preview and consent code run unchanged.
class PreflightWallet extends GuardianDappWallet {
  bool paused = false;
  PreflightWallet(DappRpc rpc) : super(rpc: rpc);
  @override
  String get account => fixture.account;
  @override
  bool get available => true;
  @override
  EpkState get policyState => EpkState(isActive: !paused);
  @override
  Future<void> checkSigningAllowed(int chainId) async {
    if (paused) throw const DappError(4100, 'Guardian protection is paused.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DappTransaction tx;
  late fixture.ReceiveRpc receiver;
  late PreflightWallet wallet;
  const origin = 'https://api.lvs.network';
  setUp(() {
    tx = DappTransaction.parse({'from': fixture.account, 'to': fixture.target,
      'data': fixture.withdrawalData(), 'gas': '0xf4240', 'gasPrice': '0x1'},
      fixture.account, 56);
    receiver = fixture.ReceiveRpc(jsonDecode(File(
      'test/services/dapp/fixtures/reviewed_receiver_bytecode.json').readAsStringSync()), tx);
    wallet = PreflightWallet(PreflightRpc(receiver));
  });
  test('production backend offers verified payout in unchanged default Safe policy', () async {
    final before = PolicyProfileStore.instance.current;
    final preview = await wallet.prepareTransaction(origin, tx);
    expect(preview.warnings, contains('oneTimeReceive'));
    expect(preview.transactionDetails['recipient'], fixture.account);
    expect(preview.transactionDetails['outgoingAssets'], '0');
    expect(preview.fee, isNotEmpty);
    await expectLater(wallet.sendTransaction(tx, isCurrent: () => true), throwsA(isA<DappError>()));
    expect(identical(before, PolicyProfileStore.instance.current), true);
    expect(before.trustedContracts, isEmpty);
  });
  test('fresh preflight keeps the first native preview for one confirmation', () async {
    final shown = await wallet.prepareTransaction(origin, tx);
    await wallet.prepareTransaction(origin, tx);
    wallet.confirmTransaction(tx, shown);
    expect(() => wallet.confirmTransaction(tx, shown), throwsA(isA<DappError>()));
    wallet.discardTransaction(tx);
    await expectLater(wallet.sendTransaction(tx, isCurrent: () => true), throwsA(isA<DappError>()));
  });
  test('changed receiver before confirmation invalidates the prepared request', () async {
    final shown = await wallet.prepareTransaction(origin, tx);
    receiver.tamperCode = fixture.implementation;
    await expectLater(wallet.prepareTransaction(origin, tx), throwsA(isA<DappError>()));
    expect(() => wallet.confirmTransaction(tx, shown), throwsA(isA<DappError>()));
  });
  test('pause blocks payout before preparation and cannot grant consent', () async {
    wallet.paused = true;
    await expectLater(wallet.prepareTransaction(origin, tx), throwsA(isA<DappError>()));
    expect(receiver.methods, isEmpty);
  });
  test('ordinary untrusted contract still cannot obtain a preview', () async {
    final arbitrary = DappTransaction.parse({...tx.params, 'data': '0x12345678'}, fixture.account, 56);
    await expectLater(wallet.prepareTransaction(origin, arbitrary), throwsA(isA<DappError>()));
  });
}
