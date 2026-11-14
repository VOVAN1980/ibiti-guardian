import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/history/tx_spam_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const usdt = '0x55d398326f99059ff775485246999027b3197955';
  const junk = '0x3e5100000000000000000000000000000000013d1';

  OnChainTx tx(OnChainTxType type, double value, {String? contract}) =>
      OnChainTx(
        hash: '0x${type.name}$value${contract ?? 'native'}',
        type: type,
        from: '0xaaaa',
        to: '0xbbbb',
        value: value,
        tokenSymbol: contract == null ? 'BNB' : 'TOKEN',
        contractAddress: contract,
        blockTimestamp: DateTime(2026, 11, 14),
        isSuccess: true,
        chainKey: 'bsc',
      );

  bool known(String c) => c == usdt;

  group('History spam filter', () {
    test('an airdrop of an unknown token is spam', () {
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.receive, 13521.68, contract: junk),
              isKnownToken: known),
          true);
    });

    test('a zero-amount transfer (address poisoning) is spam both ways', () {
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.receive, 0, contract: usdt),
              isKnownToken: known),
          true);
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.send, 0, contract: usdt),
              isKnownToken: known),
          true);
    });

    test('real USDT received, own sends and native coins stay visible', () {
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.receive, 5, contract: usdt),
              isKnownToken: known),
          false);
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.send, 1.1, contract: usdt),
              isKnownToken: known),
          false);
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.receive, 0.01),
              isKnownToken: known),
          false);
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.approval, 0, contract: usdt),
              isKnownToken: known),
          false);
    });

    test('a token the user has sent themselves is never spam', () {
      expect(
          TxSpamFilter.isSpam(tx(OnChainTxType.receive, 10, contract: junk),
              isKnownToken: known, sentTokens: {junk}),
          false);
    });
  });

  test('finished transactions survive an app restart', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = TxRegistry.instance..clear();
    registry.push(TxStatusEvent(
      status: TxStatus.confirmed,
      txHash: '0xabc',
      timestamp: DateTime.now(),
      operationLabel: 'Send 1.1 USDT',
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A new run starts with an empty in-memory list and loads the saved one.
    final saved = (await SharedPreferences.getInstance())
        .getString('tx_registry_recent_v1');
    expect(saved, contains('0xabc'));
    registry.clear(); // the new run's empty in-memory list
    await Future<void>.delayed(const Duration(milliseconds: 50));
    SharedPreferences.setMockInitialValues({'tx_registry_recent_v1': saved!});
    await registry.load();
    expect(registry.history.single.operationLabel, 'Send 1.1 USDT');
    expect(registry.history.single.isTerminal, true);
  });
}
