import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/execution/transaction_builder.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

void main() {
  const recipient = '0x347198c594dfea6d731e5f54ac699f73e0d228d7';
  const bscUsdt = '0x55d398326f99059fF775485246999027B3197955';

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Connected wallet on BSC.
    IBITIVaultService.instance.setVaultCreatedForTest(
      evmAddress: '0x9999999999999999999999999999999999999999',
    );
  });

  IntentData send(String symbol, double amount, {BigInt? rawAmount}) =>
      IntentData(
        type: IntentType.sendAsset,
        rawInput: 'send',
        tokenSymbol: symbol,
        toAddress: recipient,
        amount: amount,
        rawAmount: rawAmount,
      );

  group('TransactionBuilder send', () {
    test('"1 USDT" with a forged rawAmount signs 1 USDT, not native coin', () {
      final tx = TransactionBuilder.build(
        send('USDT', 1, rawAmount: BigInt.parse('3000000000000000000')),
      )!;

      expect(tx.tokenContract, bscUsdt);
      expect(tx.tokenDecimals, 18);
      expect(tx.rawAmount, BigInt.parse('1000000000000000000'));
      expect(tx.atomicAmount, BigInt.parse('1000000000000000000'));
    });

    test('native BNB send has no contract and 18 decimals', () {
      final tx = TransactionBuilder.build(send('bnb', 0.5))!;

      expect(tx.tokenContract, isNull);
      expect(tx.tokenSymbol, 'BNB');
      expect(tx.rawAmount, BigInt.parse('500000000000000000'));
      expect(tx.chainId, 56);
    });

    test('ETH on BSC resolves to Binance-Peg ETH', () {
      final tx = TransactionBuilder.build(send('ETH', 5))!;

      expect(tx.tokenContract, '0x2170Ed0880ac9A755fd29B2688956BD959F933F8');
      expect(tx.rawAmount, BigInt.parse('5000000000000000000'));
    });

    test('token not known on this chain is refused', () {
      expect(TransactionBuilder.build(send('NOTATOKEN', 1)), isNull);
    });

    test('recipient address shape is checked per chain', () {
      expect(TransactionBuilder.isValidRecipient(recipient, 'bsc'), isTrue);
      // A short address used to be zero-padded into a different address.
      expect(TransactionBuilder.isValidRecipient('0x1234', 'bsc'), isFalse);
      expect(TransactionBuilder.build(IntentData(
            type: IntentType.sendAsset,
            rawInput: 'send',
            tokenSymbol: 'BNB',
            toAddress: '0x1234',
            amount: 1,
          )), isNull);
      expect(
          TransactionBuilder.isValidRecipient(
              'BHZrgWe7xD9C2W7hEDyGfqB2Lxe1L7ttPDDFkAhvhLfC', 'solana'),
          isTrue);
      expect(TransactionBuilder.isValidRecipient('0xabc', 'solana'), isFalse);
      expect(
          TransactionBuilder.isValidRecipient(
              'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t', 'tron'),
          isTrue);
      expect(TransactionBuilder.isValidRecipient(recipient, 'tron'), isFalse);
    });

    test('zero amount is refused', () {
      expect(TransactionBuilder.build(send('USDT', 0)), isNull);
    });
  });
}
