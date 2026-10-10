import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/screens/wallet/tx_detail_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_transaction_history_screen.dart';
import 'package:ibiti_guardian/services/history/tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

const _wallet = '0x1111111111111111111111111111111111111111';
const _other = '0x2222222222222222222222222222222222222222';

OnChainTx _tx(String hash, OnChainTxType type, {int seconds = 0}) => OnChainTx(
      hash: hash,
      type: type,
      from: type == OnChainTxType.receive ? _other : _wallet,
      to: type == OnChainTxType.receive ? _wallet : _other,
      value: type == OnChainTxType.receive ? 0.5 : 0,
      tokenSymbol: type == OnChainTxType.receive ? 'TEST' : null,
      blockTimestamp:
          DateTime.utc(2026, 10, 10).add(Duration(seconds: seconds)),
      isSuccess: true,
      chainKey: 'bsc',
      feeNative: 0.000021,
      feeSymbol: 'BNB',
    );

class _PagedSource implements TxHistorySource {
  _PagedSource(this.first, this.last);
  final List<OnChainTx> first;
  final List<OnChainTx> last;
  final cursors = <String?>[];
  @override
  String get name => 'test';
  @override
  bool supports(String chainKey) => chainKey == 'bsc';
  @override
  Future<bool> isConfigured() async => true;
  @override
  Future<HistoryPage> fetch(
      {required String address,
      required String chainKey,
      String? cursor}) async {
    cursors.add(cursor);
    return cursor == null
        ? HistoryPage(first, 'older')
        : HistoryPage(last, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<TxHistorySource> saved;
  setUp(() async {
    saved = TxHistoryService.sources;
    await LocalizationService.instance.load(const Locale('ru'));
  });
  tearDown(() => TxHistoryService.sources = saved);

  String text(String key, [Map<String, dynamic>? args]) =>
      LocalizationService.instance.t(key, args);

  Future<void> open(WidgetTester tester, _PagedSource source) async {
    TxHistoryService.sources = [source];
    await tester.pumpWidget(const MaterialApp(
        home: WalletTransactionHistoryScreen(walletAddress: _wallet)));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty filter still lets the user load older matching rows',
      (tester) async {
    final source = _PagedSource([_tx('one', OnChainTxType.receive)],
        [_tx('approval', OnChainTxType.approval, seconds: -10)]);
    await open(tester, source);
    await tester.tap(find.text(text('txFilterApprovals')));
    await tester.pumpAndSettle();
    expect(find.text(text('txHistoryLoadMore')), findsOneWidget);
    await tester.tap(find.text(text('txHistoryLoadMore')));
    await tester.pumpAndSettle();
    expect(find.text(text('txRowApproval')), findsOneWidget);
    expect(source.cursors, [null, 'older']);
    expect(find.text(text('txHistoryLoadMore')), findsNothing);
  });

  testWidgets('an enriched row replaces the old row and opens Russian details',
      (tester) async {
    final source = _PagedSource([_tx('same', OnChainTxType.other)],
        [_tx('same', OnChainTxType.receive)]);
    await open(tester, source);
    expect(find.text(text('txRowTransaction')), findsOneWidget);
    await tester.tap(find.text(text('txHistoryLoadMore')));
    await tester.pumpAndSettle();
    final title = text('txRowReceived', {'token': 'TEST'});
    expect(find.text(title), findsOneWidget);
    expect(find.text(text('txRowTransaction')), findsNothing);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(find.byType(TxDetailScreen), findsOneWidget);
    expect(find.text(text('txDetailTitle')), findsOneWidget);
    expect(find.text(text('txDetailFee')), findsOneWidget);
    expect(find.text('0.000021 BNB'), findsOneWidget);
    final details = tester.widget<TxDetailScreen>(find.byType(TxDetailScreen));
    expect(details.tx.hash, 'same');
    expect(details.tx.value, 0.5);
    expect(details.tx.from, _other);
    expect(details.tx.to, _wallet);
    expect(details.tx.feeNative, 0.000021);
  });
}
