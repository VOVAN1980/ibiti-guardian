import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_transaction_history_screen.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_history_store.dart';
import 'package:ibiti_guardian/services/history/tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exchange orders (the AI's and the user's own) are in the common
/// transaction history with the «Биржа» / "Exchange" label and filter chip;
/// the «ИИ выполнил» notification opens the order.
const _wallet = '0x1111111111111111111111111111111111111111';
const _other = '0x2222222222222222222222222222222222222222';

OnChainTx _received(String hash, DateTime at) => OnChainTx(
      hash: hash,
      type: OnChainTxType.receive,
      from: _other,
      to: _wallet,
      value: 0.5,
      tokenSymbol: 'TEST',
      blockTimestamp: at,
      isSuccess: true,
      chainKey: 'bsc',
      feeNative: 0.000021,
      feeSymbol: 'BNB',
    );

class _OnePageSource implements TxHistorySource {
  _OnePageSource(this.txs);
  final List<OnChainTx> txs;
  @override
  String get name => 'test';
  @override
  bool supports(String chainKey) => true;
  @override
  Future<bool> isConfigured() async => true;
  @override
  Future<HistoryPage> fetch(
          {required String address,
          required String chainKey,
          String? cursor}) async =>
      HistoryPage(txs, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = ExchangeOrderHistoryStore.instance;
  late List<TxHistorySource> saved;
  late String orderId;

  final t = LocalizationService.instance;
  // The same texts the screen shows (translated once the keys exist).
  String bought(String symbol) =>
      t.t('txExchangeBought', {'token': symbol, 'default': 'Bought $symbol'});
  String detailTitle() =>
      t.t('txExchangeDetailTitle', {'default': 'Exchange order'});
  String receivedRow() => t.t('txRowReceived', {'token': 'TEST'});

  setUp(() async {
    saved = TxHistoryService.sources;
    SharedPreferences.setMockInitialValues({});
    store.resetForTest();
    final order = await store.record(
      exchange: 'mexc',
      symbol: 'SOL',
      quote: 'USDT',
      isBuy: true,
      amount: 20,
      price: 100,
      executedQty: 0.2,
      status: ExchangeOrderRecord.statusFilled,
      byAi: true,
      orderId: '777',
      time: DateTime.utc(2026, 10, 10, 0, 0, 30),
    );
    orderId = order.id;
    TxHistoryService.sources = [
      _OnePageSource([_received('one', DateTime.utc(2026, 10, 10))]),
    ];
  });
  tearDown(() => TxHistoryService.sources = saved);

  testWidgets('the common history lists exchange orders among transactions',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: WalletTransactionHistoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text(bought('SOL')), findsOneWidget);
    expect(find.text(receivedRow()), findsOneWidget);
    // Newest first: the order (00:00:30) above the transfer (00:00:00).
    expect(tester.getTopLeft(find.text(bought('SOL'))).dy,
        lessThan(tester.getTopLeft(find.text(receivedRow())).dy));

    // Tapping the order opens its details.
    await tester.tap(find.text(bought('SOL')));
    await tester.pumpAndSettle();
    expect(find.text(detailTitle()), findsOneWidget);
    expect(find.text('MEXC'), findsOneWidget);
    expect(find.text('777'), findsOneWidget);
  });

  testWidgets('the exchange chip shows only exchange orders', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: WalletTransactionHistoryScreen()));
    await tester.pumpAndSettle();

    final chip = t.t('txFilterExchange', {'default': 'Exchange'});
    // The chips scroll sideways; bring the last one (Exchange) into view
    // first, so the tap hits the chip and not an order row's label.
    final chipList = find.byWidgetPredicate((w) =>
        w is ListView && w.scrollDirection == Axis.horizontal);
    await tester.dragUntilVisible(
        find.descendant(of: chipList, matching: find.text(chip)),
        chipList,
        const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: chipList, matching: find.text(chip)));
    await tester.pumpAndSettle();
    expect(find.text(bought('SOL')), findsOneWidget);
    expect(find.text(receivedRow()), findsNothing);
  });

  testWidgets('the notification opens the order it names', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: WalletTransactionHistoryScreen(focusId: orderId)));
    await tester.pumpAndSettle();
    expect(find.text(detailTitle()), findsOneWidget);
    expect(find.text('777'), findsOneWidget);
  });

  // D10 + review finding (wallet_transaction_history_screen.dart:71): orders
  // are not tied to a card address. The history the user opens by hand
  // (Wallet → card → «История транзакций», with the card's address) shows
  // them — the AI's and the user's own — and the «Биржа» chip too.
  testWidgets(
      'a card\'s history (opened by hand) shows exchange orders and the chip',
      (tester) async {
    // Real async storage work must run outside the widget test's fake clock.
    await tester.runAsync(() => store.record(
      exchange: 'binance',
      symbol: 'ETH',
      quote: 'USDT',
      isBuy: true,
      amount: 15,
      price: 3000,
      executedQty: 0.005,
      status: ExchangeOrderRecord.statusFilled,
      byAi: false, // the user's own order from the Market window
      orderId: '888',
      time: DateTime.utc(2026, 10, 10, 0, 0, 10),
    ));
    await tester.pumpWidget(const MaterialApp(
        home: WalletTransactionHistoryScreen(walletAddress: _wallet)));
    await tester.pumpAndSettle();
    expect(find.text(bought('SOL')), findsOneWidget, reason: 'the AI order');
    expect(find.text(bought('ETH')), findsOneWidget, reason: 'the user order');
    expect(find.text(receivedRow()), findsOneWidget);

    final chip = t.t('txFilterExchange', {'default': 'Exchange'});
    final chipList = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal);
    await tester.dragUntilVisible(
        find.descendant(of: chipList, matching: find.text(chip)),
        chipList,
        const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: chipList, matching: find.text(chip)));
    await tester.pumpAndSettle();
    expect(find.text(bought('SOL')), findsOneWidget);
    expect(find.text(bought('ETH')), findsOneWidget);
    expect(find.text(receivedRow()), findsNothing);
  });

  testWidgets('a card\'s history also opens the order the notification names',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: WalletTransactionHistoryScreen(
            walletAddress: _wallet, focusId: orderId)));
    await tester.pumpAndSettle();
    expect(find.text(detailTitle()), findsOneWidget);
    expect(find.text('777'), findsOneWidget);
  });
}
