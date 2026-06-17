import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/audio_manager.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/adapters/portfolio_adapter.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/wallet/wallet_price_enricher.dart';

// ─── Wallet Top-up Detector ──────────────────────────────────────────────────
//
// Detects real balance increases (token amount, NOT USD price change)
// and plays a pleasant coin sound + shows a notification.
//
// Background / Foreground monitoring:
//   - Persists balance snapshot to SharedPreferences between runs.
//   - Dynamic polling interval: 15 seconds in foreground, 2 minutes in background.
//   - Checks all supported chains and linked wallets in parallel.
//   - Syncs background balance updates directly to VaultPortfolioListener cache.
// ─────────────────────────────────────────────────────────────────────────────

class WalletTopUpDetector with WidgetsBindingObserver {
  WalletTopUpDetector._();
  static final instance = WalletTopUpDetector._();

  static const _log = GuardianLogger('TopUpDetector');
  static const _storageKey = 'wallet_topup_balances';

  /// key = "$address_$chainKey:$symbol:$contractAddress"  value = token amount
  final Map<String, double> _prevBalances = {};

  /// Track which wallet (address_chainKey) has set its baseline
  final Set<String> _baselinedWallets = {};

  String _lastEvmAddress = '';
  String _lastSolAddress = '';
  String _lastTronAddress = '';

  bool _isChecking = false;

  DateTime _lastSoundAt = DateTime(2000);
  static const _debounce = Duration(seconds: 10);

  Timer? _pollTimer;
  Duration _currentInterval = const Duration(minutes: 2);

  // ── Lifecycle & Disk Persistence ───────────────────────────────────────────

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null) {
        final Map<String, dynamic> decoded = jsonDecode(raw);
        _prevBalances.clear();
        decoded.forEach((k, v) {
          _prevBalances[k] = (v as num).toDouble();
        });

        // Populate baselined wallets from loaded keys
        _baselinedWallets.clear();
        for (final key in _prevBalances.keys) {
          final parts = key.split(':');
          if (parts.isNotEmpty) {
            _baselinedWallets.add(parts[0]);
          }
        }
        _log.d('Restored ${_prevBalances.length} balances from disk, baselined ${_baselinedWallets.length} wallets');
      }
    } catch (e) {
      _log.w('Failed to load balances from disk: $e');
    }
  }

  Future<void> _saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(_prevBalances));
    } catch (e) {
      _log.w('Failed to save balances to disk: $e');
    }
  }

  /// Start monitoring and register lifecycle listener. Called once at boot screen.
  void start() async {
    WidgetsBinding.instance.removeObserver(instance);
    WidgetsBinding.instance.addObserver(instance);

    await _loadFromDisk();

    // Set initial baseline addresses
    final vault = IBITIVaultService.instance;
    _lastEvmAddress = vault.evmAddress ?? '';
    _lastSolAddress = vault.solanaAddress ?? '';
    _lastTronAddress = vault.tronAddress ?? '';

    // Run first check immediately
    checkAllBalances();

    // Default to fast polling on startup (assuming app starts in foreground)
    _setPollingInterval(const Duration(seconds: 15));
    _log.d('Started successfully');
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(instance);
    _pollTimer?.cancel();
    _pollTimer = null;
    _log.d('Stopped');
  }

  void _setPollingInterval(Duration interval) {
    if (_pollTimer != null && _currentInterval == interval) return;
    _currentInterval = interval;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) {
      _log.d('Auto-poll timer fired: checking balances');
      checkAllBalances();
    });
    _log.d('Polling interval set to ${interval.inSeconds}s');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _log.d('App returned to foreground: switching to fast 15s polling');
      _setPollingInterval(const Duration(seconds: 15));
      checkAllBalances();
    } else if (state == AppLifecycleState.paused) {
      _log.d('App went to background: switching to slow 2m polling');
      _setPollingInterval(const Duration(minutes: 2));
    }
  }

  // ── Core detection ──────────────────────────────────────────────────────────

  /// Checks balances across all linked wallets and supported networks in parallel.
  Future<void> checkAllBalances() async {
    if (_isChecking) return;
    _isChecking = true;

    try {
      final vault = IBITIVaultService.instance;
      if (!vault.isVaultCreated) {
        reset();
        return;
      }

      final evmAddress = vault.evmAddress ?? '';
      final solAddress = vault.solanaAddress ?? '';
      final tronAddress = vault.tronAddress ?? '';

      // Reset baselined wallets if the accounts changed
      if (evmAddress != _lastEvmAddress ||
          solAddress != _lastSolAddress ||
          tronAddress != _lastTronAddress) {
        _log.d('Wallet addresses changed (switch account), resetting baseline');
        _lastEvmAddress = evmAddress;
        _lastSolAddress = solAddress;
        _lastTronAddress = tronAddress;
        reset();
      }

      final chains = PrivyChainRegistry.supportedChains;
      final futures = <Future<void>>[];

      for (final chain in chains) {
        String? address;
        if (chain.isSolana) {
          address = solAddress;
        } else if (chain.isTron) {
          address = tronAddress;
        } else {
          address = evmAddress;
        }

        if (address.isEmpty) continue;

        final chainKey = chain.chainKey;

        futures.add(() async {
          try {
            var summary = await PortfolioAdapter.instance.fetchSummary(
              address!,
              chainKey,
            );

            // Enrich summary with prices so notifications can show USD equivalents
            try {
              final enriched = await WalletPriceEnricher.instance.enrich(summary.allAssets);
              final enrichedSummary = PortfolioSummary(
                totalBalanceUsd: summary.totalBalanceUsd,
                assetsCount: summary.assetsCount,
                allAssets: enriched,
                address: summary.address,
                networkName: summary.networkName,
                chainKey: summary.chainKey,
                isSupported: summary.isSupported,
              ).withPerformance();
              
              final sumAssetsUsd = enrichedSummary.allAssets.fold<double>(0.0, (s, a) => s + a.valueUsd);
              _log.d('topup_detector: $chainKey totalBalanceUsd=${enrichedSummary.totalBalanceUsd}, sumAssetsUsd=$sumAssetsUsd');
              summary = enrichedSummary;
            } catch (_) {}

            // Detect balance changes
            _checkPortfolioForTopUp(summary);

            // Cache immediately in VaultPortfolioListener for reactive UI updates
            VaultPortfolioListener.instance.updateSummaryCache(address, chainKey, summary);
          } catch (e) {
            _log.e('Failed to fetch/check balance for $chainKey ($address): $e');
          }
        }());
      }

      await Future.wait(futures);
    } catch (e) {
      _log.e('Error during checkAllBalances: $e');
    } finally {
      _isChecking = false;
    }
  }

  /// Direct entry point for manual/pull-to-refresh checks from the main UI.
  void onPortfolioRefresh(PortfolioSummary summary) {
    _checkPortfolioForTopUp(summary);
  }

  void _checkPortfolioForTopUp(PortfolioSummary summary) {
    final walletKey = '${summary.address.toLowerCase()}_${summary.chainKey}';

    // If first check for this wallet/chain, set baseline silently
    if (!_baselinedWallets.contains(walletKey)) {
      _snapshotBalances(summary, walletKey);
      _baselinedWallets.add(walletKey);
      _saveToDisk();
      _log.d('Set silent baseline: ${_prevBalances.length} assets for $walletKey');
      return;
    }

    _log.d('Checking ${summary.allAssets.length} assets for $walletKey...');

    final increases = <_TopUpEntry>[];
    for (final asset in summary.allAssets) {
      final key = '$walletKey:${asset.symbol}:${asset.address}';
      final prev = _prevBalances[key] ?? 0.0;
      final now = asset.balance;

      if (now > prev) {
        increases.add(_TopUpEntry(
          symbol: asset.symbol,
          delta: now - prev,
          priceUsd: asset.priceUsd,
        ));
        _log.d('↑ Top-up detected: +${(now - prev).toStringAsFixed(6)} ${asset.symbol}');
      }
    }

    _snapshotBalances(summary, walletKey);
    _saveToDisk();

    if (increases.isEmpty) {
      return;
    }

    // Debounce audio signals
    final sinceLastSound = DateTime.now().difference(_lastSoundAt);
    if (sinceLastSound < _debounce) {
      _log.d('Audio alert debounced (${sinceLastSound.inSeconds}s < ${_debounce.inSeconds}s)');
      return;
    }
    _lastSoundAt = DateTime.now();

    final ss = SettingsService.instance.settings.soundSettings;

    // Play top-up sound
    if (ss.topUpSoundEnabled) {
      _log.d('🎵 Playing top-up sound');
      AudioManager.instance.playTopUp();
    }

    // Always show notification (works in background too)
    final body = _buildBody(increases);
    _log.d('📲 Triggering notification: $body | ${summary.networkName}');
    NotificationService.instance.showTopUpNotification(
      title: 'Пополнение кошелька',
      body: body,
      chainLabel: summary.networkName,
    );
  }

  void _snapshotBalances(PortfolioSummary summary, String walletKey) {
    for (final asset in summary.allAssets) {
      _prevBalances['$walletKey:${asset.symbol}:${asset.address}'] =
          asset.balance;
    }
  }

  String _buildBody(List<_TopUpEntry> entries) {
    if (entries.length == 1) {
      final e = entries.first;
      final usd = e.delta * e.priceUsd;
      return usd > 0.01
          ? '+${_fmt(e.delta)} ${e.symbol} (\$${usd.toStringAsFixed(2)})'
          : '+${_fmt(e.delta)} ${e.symbol}';
    }
    final parts = entries.take(3).map((e) => '+${_fmt(e.delta)} ${e.symbol}');
    final suffix = entries.length > 3 ? ', ещё ${entries.length - 3}' : '';
    return '${parts.join(', ')}$suffix';
  }

  static String _fmt(double v) {
    if (v >= 1) return v.toStringAsFixed(2);
    if (v >= 0.001) return v.toStringAsFixed(4);
    return v.toStringAsFixed(8);
  }

  /// Clears all stored baseline references and saves empty state to disk.
  void reset() {
    _prevBalances.clear();
    _baselinedWallets.clear();
    _saveToDisk();
    _log.d('Reset completed');
  }
}

class _TopUpEntry {
  final String symbol;
  final double delta;
  final double priceUsd;
  const _TopUpEntry({
    required this.symbol,
    required this.delta,
    required this.priceUsd,
  });
}
