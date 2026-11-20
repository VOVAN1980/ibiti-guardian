// AutomationIntentBuilder: AI buys / sells are built on the ACTIVE network
// only (C8), from real prices only, and never guess a token.
//
// Run: flutter test test/services/market/automation_intent_builder_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/market/automation_intent_builder.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';
const _usdtBsc = '0x55d398326f99059fF775485246999027B3197955';
const _cakeBsc = '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82';

WalletAsset _asset({
  required String symbol,
  required String address,
  required double balance,
  required double price,
  int chainId = 56,
  String chainKey = 'bsc',
  bool isNative = false,
  bool priceAvailable = true,
}) =>
    WalletAsset(
      name: symbol,
      symbol: symbol,
      address: address,
      balance: balance,
      priceUsd: price,
      valueUsd: balance * price,
      decimals: 18,
      chainId: chainId,
      chainKey: chainKey,
      isNative: isNative,
      priceAvailable: priceAvailable,
    );

void _portfolio(List<WalletAsset> assets) {
  VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
    totalBalanceUsd: assets.fold(0.0, (s, a) => s + a.valueUsd),
    assetsCount: assets.length,
    allAssets: assets,
    address: _owner,
    networkName: 'BNB Chain',
    chainKey: 'bsc',
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: _owner);
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.fullAutonomy,
    ));
  });

  group('buildTrade', () {
    test('buy by dollars: stablecoin → coin on the active network', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'cake', isBuy: true, amountUsd: 25);
      expect(r, isA<AutomationIntentReady>());
      final ready = r as AutomationIntentReady;
      expect(ready.chainKey, 'bsc');
      expect(ready.intent.type, IntentType.swapAsset);
      expect(ready.intent.sourceTokenSymbol, 'USDT');
      expect(ready.intent.sourceTokenAddress, _usdtBsc);
      expect(ready.intent.targetTokenSymbol, 'CAKE');
      expect(ready.intent.targetTokenAddress, _cakeBsc);
      expect(ready.intent.amount, closeTo(25, 1e-9));
      expect(ready.valueUsd, closeTo(25, 1e-9));
      expect(ready.intent.sourceTrigger, isNull);
    });

    test('sell by quantity: coin → stablecoin', () {
      _portfolio([
        _asset(symbol: 'CAKE', address: _cakeBsc, balance: 10, price: 2),
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 5, price: 1),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: false, quantity: 4);
      final ready = r as AutomationIntentReady;
      expect(ready.intent.sourceTokenSymbol, 'CAKE');
      expect(ready.intent.targetTokenSymbol, 'USDT');
      expect(ready.intent.amount, 4);
      expect(ready.valueUsd, closeTo(8, 1e-9));
    });

    test('the native coin uses the swap provider sentinel', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
        _asset(
            symbol: 'BNB',
            address: 'native',
            balance: 1,
            price: 600,
            isNative: true),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'BNB', isBuy: true, amountUsd: 30);
      final ready = r as AutomationIntentReady;
      expect(ready.intent.targetTokenAddress,
          ZeroXSwapProvider.nativeTokenSentinel);
      expect(ready.intent.targetTokenDecimals, 18);
    });

    test('never sizes from a guessed price', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
      ]);
      // Buying 3 CAKE needs CAKE's price: not held, none given → blocked.
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'CAKE', isBuy: true, quantity: 3),
        isA<AutomationIntentBlocked>(),
      );
      // With a real price from the caller it works.
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: true, quantity: 3, priceUsd: 2);
      expect((r as AutomationIntentReady).intent.amount, closeTo(6, 1e-9));
    });

    test('a coin that cannot be resolved on this network is not guessed', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
      ]);
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'NOSUCHCOIN', isBuy: true, amountUsd: 10),
        isA<AutomationIntentBlocked>(),
      );
    });

    test('a coin held only on another network is not traded here', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
        _asset(
            symbol: 'PEPE',
            address: '0x6982508145454Ce325dDbE47a25d4ec3d2311933',
            balance: 1000000,
            price: 0.00001,
            chainId: 1,
            chainKey: 'eth'),
      ]);
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'PEPE', isBuy: false, quantity: 10),
        isA<AutomationIntentBlocked>(),
      );
    });

    test('more than the balance, no amount, or sell-all is refused', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 20, price: 1),
        _asset(symbol: 'CAKE', address: _cakeBsc, balance: 1, price: 2),
      ]);
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'CAKE', isBuy: true, amountUsd: 50),
        isA<AutomationIntentBlocked>(),
      );
      expect(
        AutomationIntentBuilder.buildTrade(symbol: 'CAKE', isBuy: true),
        isA<AutomationIntentBlocked>(),
      );
      // «всё» / «половину» arrive as -1 / -0.5: the window handles those.
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'CAKE', isBuy: false, quantity: -1),
        isA<AutomationIntentBlocked>(),
      );
    });

    test('a network outside «AI Мандат» is refused', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        mandate: AutonomyMandate(allowedNetworks: ['eth']),
      ));
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
      ]);
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'CAKE', isBuy: true, amountUsd: 10),
        isA<AutomationIntentBlocked>(),
      );
    });
  });

  group('buildBuyForSymbol', () {
    test('sizes by the mandate cap and reports the network and source', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 500, price: 1),
      ]);
      final r = AutomationIntentBuilder.buildBuyForSymbol('CAKE');
      final ready = r as AutomationIntentReady;
      expect(ready.chainKey, 'bsc');
      expect(ready.sourceAsset?.symbol, 'USDT');
      expect(ready.intent.amount, 100); // default max position $100
      expect(ready.valueUsd, 100);
    });
  });
}
