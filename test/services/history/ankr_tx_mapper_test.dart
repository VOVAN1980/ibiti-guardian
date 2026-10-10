import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/ankr/ankr_tx_history_service.dart';

// Synthetic wallet address: no user's account belongs in a committed fixture.
const _me = '0x1010101010101010101010101010101010101010';
const _vault = '0x7c1ba66011c65603caa7f892069e9b330406ac39';
const _usdt = '0x55d398326f99059ff775485246999027b3197955';
const _cake = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82';
const _other = '0x1111111111111111111111111111111111111111';

Map<String, dynamic> _tx({
  required String hash,
  required String from,
  required String to,
  String value = '0x0',
  String status = '0x1',
  String input = '0x',
  String gasUsed = '0x5208', // 21000
  String gasPrice = '0x3b9aca00', // 1 gwei
  String timestamp = '0x6700a000',
}) =>
    {
      'hash': hash,
      'from': from,
      'to': to,
      'value': value,
      'status': status,
      'input': input,
      'gasUsed': gasUsed,
      'gasPrice': gasPrice,
      'timestamp': timestamp,
    };

Map<String, dynamic> _leg({
  required String hash,
  required String from,
  required String to,
  required String symbol,
  required String contract,
  String value = '1',
  int timestamp = 1728127000,
}) =>
    {
      'transactionHash': hash,
      'fromAddress': from,
      'toAddress': to,
      'tokenSymbol': symbol,
      'tokenName': symbol,
      'tokenDecimals': 18,
      'contractAddress': contract,
      'value': value,
      'timestamp': timestamp,
    };

List<OnChainTx> _map(
  List<Map<String, dynamic>> txs,
  List<Map<String, dynamic>> legs,
) =>
    AnkrTxMapper.map(
      transactions: txs,
      transfers: legs,
      wallet: _me.toUpperCase().replaceFirst('0X', '0x'),
      chainKey: 'bsc',
      nativeSymbol: 'BNB',
    );

void main() {
  test('an LVS withdrawal: the wallet pays gas, the vault sends USDT back', () {
    final result = _map(
      [
        _tx(
            hash: '0xaa',
            from: _me,
            to: _vault,
            gasUsed: '0x30d40',
            gasPrice: '0x2540be400')
      ],
      [
        _leg(
            hash: '0xaa',
            from: _vault,
            to: _me,
            symbol: 'USDT',
            contract: _usdt,
            value: '0.5')
      ],
    );
    expect(result, hasLength(1));
    final tx = result.single;
    expect(tx.type, OnChainTxType.receive);
    expect(tx.tokenSymbol, 'USDT');
    expect(tx.value, 0.5);
    expect(tx.from, _vault);
    expect(tx.to, _me);
    expect(tx.isSuccess, isTrue);
    // 200000 gas * 10 gwei = 0.002 BNB, paid by this wallet.
    expect(tx.feeNative, closeTo(0.002, 1e-12));
    expect(tx.feeSymbol, 'BNB');
    expect(tx.hash, '0xaa');
  });

  test('a native send, an incoming native transfer and a plain contract call',
      () {
    final result = _map([
      _tx(
          hash: '0xb1',
          from: _me,
          to: _other,
          value: '0xde0b6b3a7640000',
          timestamp: '0x6700a003'),
      _tx(
          hash: '0xb2',
          from: _other,
          to: _me,
          value: '0x2c68af0bb140000',
          timestamp: '0x6700a002'),
      _tx(hash: '0xb3', from: _me, to: _vault, timestamp: '0x6700a001'),
    ], const []);
    expect(result.map((t) => t.hash), ['0xb1', '0xb2', '0xb3'],
        reason: 'newest first');
    expect(result[0].type, OnChainTxType.send);
    expect(result[0].value, 1.0);
    expect(result[0].tokenSymbol, 'BNB');
    expect(result[1].type, OnChainTxType.receive);
    expect(result[1].value, closeTo(0.2, 1e-12));
    expect(result[1].feeNative, isNull, reason: 'someone else paid the fee');
    expect(result[2].type, OnChainTxType.other);
  });

  test('a token approval is recognised from the call data', () {
    const spender = '1234567890abcdef1234567890abcdef12345678';
    final input = '0x095ea7b3${'0' * 24}$spender${'f' * 64}';
    final result =
        _map([_tx(hash: '0xc1', from: _me, to: _usdt, input: input)], const []);
    final tx = result.single;
    expect(tx.type, OnChainTxType.approval);
    expect(tx.to, '0x$spender');
    expect(tx.contractAddress, _usdt);
  });

  test('two different tokens in one transaction are a swap', () {
    final result = _map(
      [_tx(hash: '0xd1', from: _me, to: _other)],
      [
        _leg(
            hash: '0xd1',
            from: _me,
            to: _other,
            symbol: 'USDT',
            contract: _usdt,
            value: '10'),
        _leg(
            hash: '0xd1',
            from: _other,
            to: _me,
            symbol: 'CAKE',
            contract: _cake,
            value: '4.2'),
      ],
    );
    final tx = result.single;
    expect(tx.type, OnChainTxType.swap);
    expect(tx.sellSymbol, 'USDT');
    expect(tx.sellValue, 10);
    expect(tx.buySymbol, 'CAKE');
    expect(tx.buyValue, 4.2);
  });

  test('a failed transaction is marked failed', () {
    final result = _map(
        [_tx(hash: '0xe1', from: _me, to: _vault, status: '0x0')], const []);
    expect(result.single.isSuccess, isFalse);
  });

  test('tokens received from a stranger appear without any transaction of ours',
      () {
    final result = _map(
      const [],
      [
        _leg(
            hash: '0xf1',
            from: _other,
            to: _me,
            symbol: 'USDC',
            contract: _usdt,
            value: '12.5')
      ],
    );
    final tx = result.single;
    expect(tx.type, OnChainTxType.receive);
    expect(tx.value, 12.5);
    expect(tx.feeNative, isNull);
  });

  test('token amounts fall back to the raw integer and its decimals', () {
    final leg = _leg(
        hash: '0xf2', from: _other, to: _me, symbol: 'USDT', contract: _usdt)
      ..remove('value')
      ..['valueRawInteger'] = '2500000000000000000'
      ..['tokenDecimals'] = '18';
    expect(_map(const [], [leg]).single.value, closeTo(2.5, 1e-12));
  });

  test('transactions that do not involve the wallet are dropped', () {
    final result =
        _map([_tx(hash: '0x91', from: _other, to: _vault)], const []);
    expect(result, isEmpty);
  });
}
