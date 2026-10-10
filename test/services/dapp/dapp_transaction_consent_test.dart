import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_transaction_consent.dart';

void main() {
  const account = '0x1111111111111111111111111111111111111111';
  const target = '0x2222222222222222222222222222222222222222';
  late DappTransaction tx;
  late DappApproval preview;
  late DappTransactionConsent consent;
  setUp(() {
    tx = DappTransaction.parse({'from': account, 'to': target}, account, 56);
    preview = DappApproval(origin: 'https://example.org', method: 'eth_sendTransaction',
        account: account, chainId: 56, content: tx.data);
    consent = DappTransactionConsent(tx, preview);
  });
  test('preview alone never permits a send', () {
    expect(() => consent.consume(tx), throwsA(isA<DappError>()));
  });
  test('native confirmation authorizes exactly one consumption', () {
    consent.confirm(tx, preview);
    consent.consume(tx);
    expect(() => consent.consume(tx), throwsA(isA<DappError>()));
    expect(() => consent.confirm(tx, preview), throwsA(isA<DappError>()));
  });
  test('copy of a request cannot reuse another request approval', () {
    final other = DappTransaction.parse(tx.params, account, 56);
    expect(() => consent.confirm(other, preview), throwsA(isA<DappError>()));
    consent.confirm(tx, preview);
    expect(() => consent.consume(other), throwsA(isA<DappError>()));
  });
  test('fabricated preview cannot authorize the native request', () {
    final other = DappApproval(origin: preview.origin, method: preview.method,
        account: account, chainId: 56, content: tx.data);
    expect(() => consent.confirm(tx, other), throwsA(isA<DappError>()));
  });
}
