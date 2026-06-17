import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

// ─── Funding Source Selector ─────────────────────────────────────────────────
//
// Shows available wallet chains and CEX exchanges with USDT balance.
// User selects a source → daily limit is validated against that balance.
//
// Selection persisted in AiControlSettings.fundingNetwork.
// Tap to select, tap again to deselect/toggle off.
// Minimum USDT/USDC balance required to buy is configurable.
// ─────────────────────────────────────────────────────────────────────────────

/// Stablecoin symbols considered as USD for trading purposes.
const _usdSymbols = {'USDT', 'USDC', 'DAI', 'BUSD', 'FDUSD'};

class FundingSourceSelector extends StatefulWidget {
  const FundingSourceSelector({super.key});

  static double sumUsdStables(List assets) {
    double sum = 0;
    for (final a in assets) {
      if (_usdSymbols.contains(a.symbol.toUpperCase())) {
        sum += a.valueUsd;
      }
    }
    return sum;
  }

  @override
  State<FundingSourceSelector> createState() => _FundingSourceSelectorState();
}

class _FundingSourceSelectorState extends State<FundingSourceSelector> {
  final Map<String, double> _exchangeBalances = {};
  final Map<String, bool> _exchangeBalanceErrors = {};
  final Map<String, bool> _isLoadingBalances = {};
  final Map<String, bool> _isConnectedExchanges = {};

  @override
  void initState() {
    super.initState();
    _loadExchangeData();
  }

  String? _okxRegion;

  Future<void> _loadExchangeData() async {
    final okxReg = await ExchangeAccountStore.instance.getOkxRegion();
    if (mounted) {
      setState(() {
        _okxRegion = okxReg;
      });
    }
    for (final ex in ['binance', 'mexc', 'gateio', 'okx']) {
      final connected = await ExchangeAccountStore.instance.isConnected(ex);
      if (mounted) {
        setState(() {
          _isConnectedExchanges[ex] = connected;
        });
      }
      if (connected) {
        final cached = ExchangeAccountStore.instance.getCachedUsdtBalance(ex);
        if (cached != null) {
          if (mounted) {
            setState(() {
              _exchangeBalances[ex] = cached;
              _isLoadingBalances[ex] = false;
              _exchangeBalanceErrors[ex] = false;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _isLoadingBalances[ex] = true;
              _exchangeBalanceErrors[ex] = false;
            });
          }
        }
        try {
          double? bal;
          if (ex == 'okx') {
            final region = _okxRegion ?? await ExchangeAccountStore.instance.getOkxRegion();
            final targetAsset = region == 'eea' ? 'USDC' : 'USDT';
            final adapter = ExchangeOrderService.instance.adapterFor('okx');
            if (adapter != null) {
              bal = await adapter.fetchAssetBalance(targetAsset);
            } else {
              bal = await ExchangeAccountStore.instance.fetchUsdtBalance(ex);
            }
          } else {
            bal = await ExchangeAccountStore.instance.fetchUsdtBalance(ex);
          }

          if (mounted) {
            setState(() {
              if (bal == null) {
                if (cached == null) {
                  _exchangeBalanceErrors[ex] = true;
                }
              } else {
                _exchangeBalances[ex] = bal;
                _exchangeBalanceErrors[ex] = false;
              }
              _isLoadingBalances[ex] = false;
            });
          }
        } catch (_) {
          if (mounted) {
            setState(() {
              if (cached == null) {
                _exchangeBalanceErrors[ex] = true;
              }
              _isLoadingBalances[ex] = false;
            });
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AiControlService.instance,
        VaultPortfolioListener.instance,
      ]),
      builder: (context, _) {
        final settings = AiControlService.instance.settings;
        final portfolio = VaultPortfolioListener.instance.summary;
        final activeSources = settings.activeSources;

        // Gather USDT balances per source
        final sources = <_FundingOption>[];

        // 1. Wallet source
        if (portfolio != null) {
          final usdBalance = FundingSourceSelector.sumUsdStables(portfolio.allAssets);
          sources.add(_FundingOption(
            network: portfolio.chainKey,
            label: portfolio.networkName,
            usdtBalance: usdBalance,
            isWallet: true,
            isConnected: true,
          ));
        } else {
          // If loading but selected, keep it visible!
          final walletKey = activeSources.firstWhere(
            (s) => s == 'bsc' || s == 'ethereum' || s == 'eth',
            orElse: () => 'bsc',
          );
          sources.add(_FundingOption(
            network: walletKey,
            label: walletKey == 'bsc' ? 'BNB Chain' : 'Ethereum',
            usdtBalance: 0.0,
            isWallet: true,
            isConnected: true,
            isLoading: true,
          ));
        }

        // 2. Exchange sources
        final exchanges = [
          {'id': 'binance', 'label': 'Binance Spot'},
          {'id': 'mexc', 'label': 'MEXC Spot'},
          {'id': 'gateio', 'label': 'Gate.io Spot'},
          {
            'id': 'okx',
            'label': _okxRegion != null ? 'OKX (${_okxRegion!.toUpperCase()}) Spot' : 'OKX Spot'
          },
        ];

        for (final ex in exchanges) {
          final id = ex['id']!;
          final label = ex['label']!;
          final connected = _isConnectedExchanges[id] ?? false;
          final balance = _exchangeBalances[id] ?? 0.0;
          final loading = _isLoadingBalances[id] ?? false;
          final hasError = _exchangeBalanceErrors[id] ?? false;

          sources.add(_FundingOption(
            network: id,
            label: label,
            usdtBalance: balance,
            isWallet: false,
            isConnected: connected,
            isLoading: loading,
            hasError: hasError,
          ));
        }

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: GuardianColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: GuardianColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ИСТОЧНИК СРЕДСТВ',
                style: GuardianTextStyles.caption.copyWith(
                  letterSpacing: 1,
                  color: GuardianColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              ...sources.map((src) => _buildSourceTile(
                    context, src, activeSources)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSourceTile(
      BuildContext context, _FundingOption src, List<String> activeSources) {
    final isSelected = activeSources.contains(src.network);
    final isConnected = src.isConnected;
    final isLoading = src.isLoading;
    final hasError = src.hasError;
    final balance = src.usdtBalance;

    final settings = AiControlService.instance.settings;
    final minTradeBal = settings.minTradeBalance;
    final hasEnoughBalance = balance >= minTradeBal;
    final insufficientBalance = isConnected && !hasEnoughBalance && !isLoading && !hasError;
    final isGrayedOut = !isConnected;

    final locale = Localizations.localeOf(context).languageCode;
    final isRu = locale == 'ru' || locale == 'uk';

    // Right side badge ON/OFF/DISABLED/CONNECT
    final Widget badge;
    if (!isConnected) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          isRu ? 'ОТКЛЮЧЕН' : 'DISABLED',
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: Colors.white38,
          ),
        ),
      );
    } else {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.greenAccent.withOpacity(0.12)
              : Colors.white10,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? Colors.greenAccent.withOpacity(0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          isSelected ? 'ON' : 'OFF',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: isSelected ? Colors.greenAccent : Colors.white54,
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: isGrayedOut
          ? () {
              if (!isConnected) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                    isRu
                        ? 'Подключите ${src.label} в модуле API ключей.'
                        : 'Connect ${src.label} first in API credentials settings.',
                  ),
                  backgroundColor: Colors.orangeAccent,
                ));
              }
            }
          : () {
              final nextSources = List<String>.from(activeSources);
              if (isSelected) {
                nextSources.remove(src.network);
              } else {
                nextSources.add(src.network);
              }
              AiControlService.instance.updateActiveSources(nextSources);
            },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? GuardianColors.accent.withOpacity(0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? GuardianColors.accent.withOpacity(0.25)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Opacity(
              opacity: isGrayedOut ? 0.35 : 1.0,
              child: Icon(
                src.isWallet ? Icons.account_balance_wallet : Icons.swap_horiz,
                size: 18,
                color: isSelected
                    ? GuardianColors.accent
                    : GuardianColors.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Opacity(
                opacity: isGrayedOut ? 0.45 : 1.0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          src.label,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: GuardianColors.textPrimary,
                          ),
                        ),
                        if (isConnected && hasError) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: _loadExchangeData,
                            child: Icon(
                              Icons.refresh_rounded,
                              size: 14,
                              color: Colors.orangeAccent.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (!isConnected)
                      const Text(
                        'Connect required',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      )
                    else if (hasError)
                      GestureDetector(
                        onTap: _loadExchangeData,
                        child: Text(
                          isRu ? 'Баланс недоступен, обновите' : 'Balance unavailable, tap refresh',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.orangeAccent.withOpacity(0.8),
                          ),
                        ),
                      )
                    else if (insufficientBalance)
                      Text(
                        isRu
                            ? 'Buy недоступен / Низкий баланс'
                            : 'Buy unavailable / Low quote balance',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.orangeAccent,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (isConnected) ...[
              if (isLoading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white30,
                  ),
                )
              else if (hasError)
                Opacity(
                  opacity: 0.5,
                  child: Text(
                    '?',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white38,
                    ),
                  ),
                )
              else
                Opacity(
                  opacity: isGrayedOut ? 0.45 : 1.0,
                  child: Text(
                    '\$${balance.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: hasEnoughBalance
                          ? Colors.greenAccent
                          : Colors.orangeAccent.withOpacity(0.7),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
            ],
            badge,
          ],
        ),
      ),
    );
  }
}

class _FundingOption {
  final String network;
  final String label;
  final double usdtBalance;
  final bool isWallet;
  final bool isConnected;
  final bool isLoading;
  final bool hasError;

  const _FundingOption({
    required this.network,
    required this.label,
    required this.usdtBalance,
    required this.isWallet,
    required this.isConnected,
    this.isLoading = false,
    this.hasError = false,
  });
}
