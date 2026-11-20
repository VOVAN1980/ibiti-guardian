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

    test('a network outside «AI Мандат» is refused (a refusal, no window)',
        () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        mandate: AutonomyMandate(allowedNetworks: ['eth']),
      ));
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: true, amountUsd: 10);
      expect(r, isA<AutomationIntentBlocked>());
      expect((r as AutomationIntentBlocked).outsideMandate, isTrue);
    });

    test('a coin that cannot be resolved is a D17 block, not a refusal', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'NOSUCHCOIN', isBuy: true, amountUsd: 10);
      expect((r as AutomationIntentBlocked).outsideMandate, isFalse);
      expect(r.reason, contains('cannot be resolved reliably'));
    });
  });

  group('look-alike tokens are never traded by the AI', () {
    // An airdropped fake: same symbol, its own contract. Wallet prices are
    // looked up by symbol, so it even shows the real coin's price.
    const fakeCake = '0x5ca3000000000000000000000000000000005ca3';
    const fakeUsdt = '0xfa4e000000000000000000000000000000000001';

    test('a buy targets the vetted contract, not a held look-alike', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 200, price: 1),
        _asset(symbol: 'CAKE', address: fakeCake, balance: 1e9, price: 2),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: true, amountUsd: 20);
      final ready = r as AutomationIntentReady;
      expect(ready.intent.targetTokenAddress, _cakeBsc);
      expect(ready.intent.targetTokenDecimals, 18);
    });

    test('selling only a look-alike cannot be resolved reliably (D17)', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 5, price: 1),
        _asset(symbol: 'CAKE', address: fakeCake, balance: 100, price: 2),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: false, quantity: 10);
      expect(r, isA<AutomationIntentBlocked>());
      expect((r as AutomationIntentBlocked).reason,
          contains('cannot be resolved reliably'));
      expect(r.outsideMandate, isFalse);
    });

    test('selling the real one ignores a look-alike next to it', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 5, price: 1),
        _asset(symbol: 'CAKE', address: fakeCake, balance: 1e9, price: 2),
        _asset(symbol: 'CAKE', address: _cakeBsc, balance: 10, price: 2),
      ]);
      final r = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: false, quantity: 4);
      final ready = r as AutomationIntentReady;
      expect(ready.intent.sourceTokenAddress, _cakeBsc);
      expect(ready.sourceAsset?.address, _cakeBsc);
      // More than the real balance is refused, whatever the fake holds.
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'CAKE', isBuy: false, quantity: 50),
        isA<AutomationIntentBlocked>(),
      );
    });

    test('a fake "USDT" never pays and never receives', () {
      _portfolio([
        _asset(symbol: 'USDT', address: fakeUsdt, balance: 1e6, price: 1),
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 50, price: 1),
        _asset(symbol: 'CAKE', address: _cakeBsc, balance: 10, price: 2),
      ]);
      final buy = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: true, amountUsd: 20) as AutomationIntentReady;
      expect(buy.intent.sourceTokenAddress, _usdtBsc);

      final sell = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: false, quantity: 2) as AutomationIntentReady;
      expect(sell.intent.targetTokenAddress, _usdtBsc);

      // Only the fake one held: the sale goes into the vetted USDT.
      _portfolio([
        _asset(symbol: 'USDT', address: fakeUsdt, balance: 1e6, price: 1),
        _asset(symbol: 'CAKE', address: _cakeBsc, balance: 10, price: 2),
      ]);
      final onlyFake = AutomationIntentBuilder.buildTrade(
          symbol: 'CAKE', isBuy: false, quantity: 2) as AutomationIntentReady;
      expect(onlyFake.intent.targetTokenAddress, _usdtBsc);
      // … and a buy has nothing real to pay with.
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'CAKE', isBuy: true, amountUsd: 20),
        isA<AutomationIntentBlocked>(),
      );
    });

    test('a token named like the native coin is not the native balance', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 50, price: 1),
        _asset(
            symbol: 'BNB',
            address: '0xb7b0000000000000000000000000000000000b7b',
            balance: 1000,
            price: 600),
      ]);
      expect(
        AutomationIntentBuilder.buildTrade(
            symbol: 'BNB', isBuy: false, quantity: 1),
        isA<AutomationIntentBlocked>(),
      );
    });

    test('a held token that is not vetted is not traded by the AI (D17)', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 50, price: 1),
        _asset(
            symbol: 'FLOKI',
            address: '0xfb5b838b6cfeedc2873ab27866079ac55363d37e',
            balance: 1000,
            price: 0.0001),
      ]);
      for (final isBuy in [true, false]) {
        final r = AutomationIntentBuilder.buildTrade(
            symbol: 'FLOKI', isBuy: isBuy, quantity: 10);
        expect(r, isA<AutomationIntentBlocked>(), reason: 'isBuy $isBuy');
        expect((r as AutomationIntentBlocked).reason,
            contains('cannot be resolved reliably'));
      }
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

    test('«Делегировать AI» buys the vetted token, not a held look-alike', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 500, price: 1),
        // Valued by its symbol: it must not use up the position either.
        _asset(
            symbol: 'CAKE',
            address: '0x5ca3000000000000000000000000000000005ca3',
            balance: 1e9,
            price: 2),
      ]);
      final ready =
          AutomationIntentBuilder.buildBuyForSymbol('CAKE') as AutomationIntentReady;
      expect(ready.intent.targetTokenAddress, _cakeBsc);
      expect(ready.intent.amount, 100);
    });

    test('the real position counts against the max position', () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 500, price: 1),
        _asset(symbol: 'CAKE', address: _cakeBsc, balance: 30, price: 2),
      ]);
      final ready =
          AutomationIntentBuilder.buildBuyForSymbol('CAKE') as AutomationIntentReady;
      expect(ready.intent.amount, closeTo(40, 1e-9)); // $100 − $60 held
    });

    test('a fake "USDT" is never the paying token', () {
      _portfolio([
        _asset(
            symbol: 'USDT',
            address: '0xfa4e000000000000000000000000000000000001',
            balance: 1e6,
            price: 1),
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 80, price: 1),
      ]);
      final ready =
          AutomationIntentBuilder.buildBuyForSymbol('CAKE') as AutomationIntentReady;
      expect(ready.sourceAsset?.address, _usdtBsc);
      expect(ready.intent.sourceTokenAddress, _usdtBsc);
      expect(ready.intent.amount, 80); // the real balance, not the fake's
    });

    test('a token that is not vetted is blocked, never taken from holdings',
        () {
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 500, price: 1),
        _asset(
            symbol: 'FLOKI',
            address: '0xfb5b838b6cfeedc2873ab27866079ac55363d37e',
            balance: 1000,
            price: 0.0001),
      ]);
      final r = AutomationIntentBuilder.buildBuyForSymbol('FLOKI');
      expect(r, isA<AutomationIntentBlocked>());
      expect((r as AutomationIntentBlocked).outsideMandate, isFalse);
      // «Делегировать AI» shows this reason on the queue item: why the AI
      // does not buy it, and that the user still can, in the window.
      expect(
          r.reason,
          contains('FLOKI is not in the app\'s verified token list on '
              'BNB Chain'));
      expect(r.reason, contains('the AI does not buy it by itself'));
      expect(r.reason,
          contains('You can buy it yourself in the Wallet or Market window'));
    });

    test('a network outside «AI Мандат» is a refusal', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        mandate: AutonomyMandate(allowedNetworks: ['eth']),
      ));
      _portfolio([
        _asset(symbol: 'USDT', address: _usdtBsc, balance: 500, price: 1),
      ]);
      final r = AutomationIntentBuilder.buildBuyForSymbol('CAKE');
      expect((r as AutomationIntentBlocked).outsideMandate, isTrue);
    });
  });
}
