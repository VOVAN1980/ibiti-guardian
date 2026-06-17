import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/adapters/portfolio_adapter.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

class AnalystResponseBuilder {
  AnalystResponseBuilder._();

  static Future<String> build({
    required String input,
    required String languageCode,
  }) async {
    final parts = <String>[];

    final wallet = WalletAdapter.instance;
    final portfolio = PortfolioAdapter.instance;

    final isConnected = wallet.isConnected;
    final address = IBITIVaultService.instance.activeAddress;
    final chainName = 'Chain ${wallet.chainId}';

    if (isConnected && address.isNotEmpty) {
      final summary = await portfolio.fetchSummary(address, wallet.chainKey);
      parts.add(_portfolioLine(
          summary.totalBalanceUsd, summary.assetsCount, languageCode));
      parts.add(_chainLine(chainName, languageCode));
    }

    // A separate live tool from LLM will inject real live price data.
    // For the baseline, we prevent the agent from inventing current numbers if not provided.
    parts.add(_noLivePriceFallback(languageCode));

    return parts.where((e) => e.trim().isNotEmpty).join(' ');
  }

  static String _portfolioLine(double totalUsd, int assetCount, String lang) {
    // toStringAsFixed(0) was rounding $0.10 → "0 dollars" → LLM hallucination.
    // Use 2 decimal places so small balances are accurate.
    final usdStr = totalUsd.toStringAsFixed(2);
    if (lang == 'ru') {
      if (totalUsd <= 0) return 'Портфель пуст — активов нет.';
      final assetPart = assetCount > 0 ? ' в $assetCount активах' : '';
      return 'Портфель: \$$usdStr$assetPart.';
    }
    if (totalUsd <= 0) return 'Portfolio is empty — no assets.';
    final assetPart = assetCount > 0 ? ' across $assetCount assets' : '';
    return 'Portfolio: \$$usdStr$assetPart.';
  }

  static String _chainLine(String chain, String lang) {
    if (lang == 'ru') return 'Активная сеть — $chain.';
    return 'Active network is $chain.';
  }

  static String _noLivePriceFallback(String lang) {
    if (lang == 'ru') {
      return '(Для свежей цены рынка используйте инструмент get_crypto_price).';
    }
    return '(A separate live tool is needed for the current market price).';
  }
}
