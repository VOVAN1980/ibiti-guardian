import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';

/// USD value of a wallet/AI transaction, for the dollar-denominated limits.
///
/// [TransactionRequest.amount] is a token quantity: comparing it with a "$50"
/// limit let 40 SOL through and blocked 60 DOGE. Limits must compare dollars.
class TxUsdValuer {
  TxUsdValuer._();

  static const _stablecoins = {
    'USDT', 'USDC', 'DAI', 'BUSD', 'FDUSD', 'TUSD', 'USDD', 'USDE', 'PYUSD',
  };

  /// Native-coin placeholders used as "token contract" by swap providers.
  static const _nativeRefs = {
    '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
    'so11111111111111111111111111111111111111112',
  };

  /// Test hook: replaces the portfolio price lookup.
  static double? Function(TransactionRequest tx)? priceOverrideForTest;

  /// Dollar value, or null when no price is known.
  static double? usdValue(TransactionRequest tx) {
    final amount = tx.amount;
    if (amount == null) return null;
    final symbol = tx.tokenSymbol?.trim().toUpperCase() ?? '';
    if (_stablecoins.contains(symbol)) return amount;
    final price = (priceOverrideForTest ?? _portfolioPrice)(tx);
    return price == null ? null : amount * price;
  }

  /// Value to compare with a dollar limit. Without a price the old
  /// quantity comparison is kept — never looser than before.
  static double limitAmount(TransactionRequest tx) =>
      usdValue(tx) ?? tx.amount ?? 0.0;

  static double? _portfolioPrice(TransactionRequest tx) {
    final List<WalletAsset> assets =
        VaultPortfolioListener.instance.summary?.allAssets ?? const [];
    final symbol = tx.tokenSymbol?.trim().toUpperCase() ?? '';
    final contract = tx.tokenContract?.trim().toLowerCase() ?? '';
    final byContract = contract.isNotEmpty && !_nativeRefs.contains(contract);

    for (final asset in assets) {
      if (!_onChain(asset, tx)) continue;
      if (!asset.priceAvailable || asset.priceUsd <= 0) continue;
      final matches = byContract
          ? asset.address.toLowerCase() == contract
          : asset.symbol.toUpperCase() == symbol && _isNative(asset);
      if (matches) return asset.priceUsd;
    }
    return null;
  }

  static bool _onChain(WalletAsset asset, TransactionRequest tx) {
    if (asset.chainKey.isNotEmpty) return asset.chainKey == tx.chainKey;
    return tx.chainId != 0 && asset.chainId == tx.chainId;
  }

  static bool _isNative(WalletAsset asset) =>
      asset.isNative || asset.address.isEmpty || asset.address == 'native';
}
