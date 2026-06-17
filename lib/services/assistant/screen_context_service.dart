import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Global singleton that tracks what the user is currently seeing on screen.
///
/// Screens publish their state here. AI reads from here to understand context
/// when the user says "this coin", "what's this?", "why is it dropping?".
///
/// No UI dependency — pure data service.
class ScreenContextService {
  ScreenContextService._();
  static final ScreenContextService instance = ScreenContextService._();

  static const _log = GuardianLogger('ScreenContext');

  /// Position where the context bubble should appear (set by long-press).
  final bubblePosition = ValueNotifier<Offset?>(null);

  // ── Active screen ─────────────────────────────────────────────────────────
  String _activeScreen =
      'ai'; // 'ai', 'chat', 'security', 'wallet', 'market', 'settings'
  String? _activeSubScreen; // 'exchange_terminal', 'token_detail', etc.

  // ── Market context ────────────────────────────────────────────────────────
  String? _activeExchange; // 'binance', 'mexc'
  String?
      _activeTerminalView; // 'fastGrowth', 'newListings', 'top', 'meme', 'majors'

  // ── Token focus ───────────────────────────────────────────────────────────
  String? _focusedSymbol;
  String? _focusedTokenName;
  double? _focusedPrice;
  double? _focusedChange24h;
  double? _focusedVolume24h;
  double? _focusedHigh24h;
  double? _focusedLow24h;
  double? _focusedMarketCap;
  String? _focusedChartRange; // '24H', '7D', '1M', '3M'

  // ── Active modal — for amount fast-path routing ────────────────────────────
  /// 'wallet_send', 'wallet_swap', or null when no modal is open.
  String? _activeModal;

  // ── Active swap field — for voice token selection routing ─────────────────
  /// 'from' or 'to' — set when user opens token picker in swap modal.
  String? _activeSwapField;

  // ── Selected tokens in active modal ───────────────────────────────────────
  /// Currently selected source token symbol in swap/send modal.
  String? _selectedFromSymbol;

  /// Currently selected target token symbol in swap modal.
  String? _selectedToSymbol;

  // ── Recent history — for "compare with previous", "what did I just see" ──
  final List<String> _recentSymbols = [];
  static const int _maxRecent = 5;

  // ── Log throttle ──────────────────────────────────────────────────────────
  String? _lastLoggedFocusSymbol;
  DateTime _lastFocusLogAt = DateTime(2000);

  // ── Getters ───────────────────────────────────────────────────────────────
  String get activeScreen => _activeScreen;
  String? get activeSubScreen => _activeSubScreen;
  String? get activeExchange => _activeExchange;
  String? get activeTerminalView => _activeTerminalView;
  String? get focusedSymbol => _focusedSymbol;
  String? get focusedTokenName => _focusedTokenName;
  double? get focusedPrice => _focusedPrice;
  double? get focusedChange24h => _focusedChange24h;
  double? get focusedVolume24h => _focusedVolume24h;
  double? get focusedHigh24h => _focusedHigh24h;
  double? get focusedLow24h => _focusedLow24h;
  double? get focusedMarketCap => _focusedMarketCap;
  String? get focusedChartRange => _focusedChartRange;
  List<String> get recentSymbols => List.unmodifiable(_recentSymbols);
  String? get activeModal => _activeModal;
  String? get activeSwapField => _activeSwapField;
  String? get selectedFromSymbol => _selectedFromSymbol;
  String? get selectedToSymbol => _selectedToSymbol;

  // ── Modal lifecycle ───────────────────────────────────────────────────────

  /// Called by modal initState to register active modal.
  void setModal(String modal) {
    _activeModal = modal;
    _log.d('Modal opened: $modal');
  }

  /// Called by modal dispose to clear the active modal.
  void clearModal() {
    _log.d('Modal closed: $_activeModal');
    _activeModal = null;
    _activeSwapField = null;
    _selectedFromSymbol = null;
    _selectedToSymbol = null;
  }

  /// Called by swap modal when user opens a token picker.
  void setSwapField(String field) {
    _activeSwapField = field;
    _log.d('Swap field: $field');
  }

  /// Called when swap picker closes.
  void clearSwapField() {
    _activeSwapField = null;
  }

  /// Called by swap/send modal when user selects a source token.
  void setSelectedFromSymbol(String? symbol) {
    _selectedFromSymbol = symbol;
    _log.d('Selected from: $symbol');
  }

  /// Called by swap modal when user selects a target token.
  void setSelectedToSymbol(String? symbol) {
    _selectedToSymbol = symbol;
    _log.d('Selected to: $symbol');
  }

  // ── Publishers ────────────────────────────────────────────────────────────

  /// Called by GuardianAppShell when user switches tabs.
  void setScreen(String screen, {String? subScreen}) {
    _activeScreen = screen;
    _activeSubScreen = subScreen;
    _log.d('Screen: $screen${subScreen != null ? ' / $subScreen' : ''}');
  }

  /// Called by ExchangeTerminalScreen when user switches exchange.
  void setExchange(String exchange) {
    _activeExchange = exchange;
    _log.d('Exchange: $exchange');
  }

  /// Called by ExchangeTerminalScreen when user switches view tab.
  void setTerminalView(String view) {
    _activeTerminalView = view;
    _log.d('View: $view');
  }

  /// Called by MarketTokenDetailScreen when user opens a token detail.
  void setFocusedToken(
    String symbol, {
    String? name,
    double? price,
    double? change24h,
    double? volume24h,
    double? high24h,
    double? low24h,
    double? marketCap,
    String? chartRange,
  }) {
    _focusedSymbol = symbol;
    _focusedTokenName = name;
    _focusedPrice = price;
    _focusedChange24h = change24h;
    _focusedVolume24h = volume24h;
    _focusedHigh24h = high24h;
    _focusedLow24h = low24h;
    _focusedMarketCap = marketCap;
    _focusedChartRange = chartRange;
    _activeSubScreen = 'token_detail';

    // Track in recent history (no duplicates, newest last)
    _recentSymbols.remove(symbol);
    _recentSymbols.add(symbol);
    if (_recentSymbols.length > _maxRecent) {
      _recentSymbols.removeAt(0);
    }

    // Throttle log — data always updates, but log at most every 2s.
    final now = DateTime.now();
    final symbolChanged = symbol != _lastLoggedFocusSymbol;
    final elapsed = now.difference(_lastFocusLogAt).inMilliseconds > 2000;
    if (symbolChanged || elapsed) {
      _log.d('Focus: $symbol (price: $price, 24h: $change24h)');
      _lastLoggedFocusSymbol = symbol;
      _lastFocusLogAt = now;
    }
  }

  /// Called when user switches chart timeframe (24H/7D/1M/3M).
  void setFocusedChartRange(String range) {
    _focusedChartRange = range;
    _log.d('Chart range: $range');
  }

  /// Called by MarketTokenDetailScreen.dispose() when user leaves detail.
  ///
  /// If [symbol] is provided, only clears if the current focus matches.
  /// This prevents a race where HYPER.dispose() clears APE's context
  /// when the user quickly navigated from HYPER → APE.
  void clearFocusedToken({String? symbol}) {
    if (symbol != null &&
        _focusedSymbol?.toLowerCase() != symbol.toLowerCase()) {
      _log.d('Skip clear: focused=$_focusedSymbol, disposing=$symbol');
      return;
    }
    _focusedSymbol = null;
    _focusedTokenName = null;
    _focusedPrice = null;
    _focusedChange24h = null;
    _focusedVolume24h = null;
    _focusedHigh24h = null;
    _focusedLow24h = null;
    _focusedMarketCap = null;
    _focusedChartRange = null;
    // Don't set _activeSubScreen here — the destination screen
    // will publish its own subScreen when it becomes active.
    _log.d('Focus cleared');
  }

  // ── AI prompt builder ─────────────────────────────────────────────────────

  /// Builds a compact context string for the LLM prompt.
  /// ~50-80 tokens, appended to [Market Context] in MarketContextBuilder.
  String buildContextPrompt() {
    final buf = StringBuffer();
    buf.writeln('[Screen Context]');
    buf.writeln(
        'The user is currently viewing this screen. Use this context to answer questions like "what is this?", "why is it dropping?" etc.');
    buf.writeln(
        "IMPORTANT: Always respond in the same language as the user's query.");
    buf.write('Screen: $_activeScreen');
    if (_activeSubScreen != null) buf.write(' / $_activeSubScreen');
    buf.writeln();

    // ── Human-readable screen description ──────────────────────────────────
    buf.writeln(_screenDescription());

    if (_activeExchange != null) {
      buf.write('Exchange: $_activeExchange');
      if (_activeTerminalView != null) {
        buf.write(' | View: $_activeTerminalView');
      }
      buf.writeln();
    }

    if (_focusedSymbol != null) {
      buf.write('Focused token: $_focusedSymbol');
      if (_focusedTokenName != null) buf.write(' ($_focusedTokenName)');
      if (_focusedPrice != null) {
        buf.write(
            ' | Price: \$${_focusedPrice!.toStringAsFixed(_focusedPrice! >= 1 ? 2 : 6)}');
      }
      if (_focusedChange24h != null) {
        final sign = _focusedChange24h! >= 0 ? '+' : '';
        buf.write(
            ' | 24h change: $sign${_focusedChange24h!.toStringAsFixed(2)}%');
      }
      buf.writeln();

      // Extended market data — gives AI full picture for analysis
      if (_focusedVolume24h != null && _focusedVolume24h! > 0) {
        buf.writeln('24h Volume: \$${_fmtLarge(_focusedVolume24h!)}');
      }
      if (_focusedHigh24h != null && _focusedHigh24h! > 0) {
        buf.write(
            '24h High: \$${_focusedHigh24h!.toStringAsFixed(_focusedHigh24h! >= 1 ? 4 : 6)}');
      }
      if (_focusedLow24h != null && _focusedLow24h! > 0) {
        buf.write(
            ' | 24h Low: \$${_focusedLow24h!.toStringAsFixed(_focusedLow24h! >= 1 ? 4 : 6)}');
      }
      if (_focusedHigh24h != null || _focusedLow24h != null) buf.writeln();
      if (_focusedMarketCap != null && _focusedMarketCap! > 0) {
        buf.writeln('Market Cap: \$${_fmtLarge(_focusedMarketCap!)}');
      }
      if (_focusedChartRange != null) {
        buf.writeln('Selected chart period: $_focusedChartRange');
      }
      buf.writeln(
          'IMPORTANT: When the user says "she", "it", "this coin", "this token", '
          '"она", "эта монета", "что думаешь", "нормальная", "какая цена", '
          '"стоит покупать", "какие риски" — they are asking about $_focusedSymbol. '
          'Answer using the data above. Do NOT ask "which coin?".');
      buf.writeln('RULE: If user asks "стоит покупать?" / "should I buy?" / '
          '"стоит продавать?" / "should I sell?" — do NOT answer yes or no. '
          'Do NOT tell the user to buy or sell. Instead, give a factual risk '
          'assessment based ONLY on the visible screen data (price change, '
          'volume, high/low range). Mention that sharp pumps carry retracement '
          'risk. Let the user decide.');
    }

    if (_recentSymbols.length > 1) {
      final previous = _recentSymbols
          .where((s) => s != _focusedSymbol)
          .toList()
          .reversed
          .take(3)
          .toList();
      if (previous.isNotEmpty) {
        buf.writeln('Recently viewed: ${previous.join(', ')}');
      }
    }

    return buf.toString().trim();
  }

  /// Returns a short description of the current screen and available actions.
  String _screenDescription() {
    if (_activeSubScreen == 'token_detail' && _focusedSymbol != null) {
      final ex = _activeExchange != null
          ? ' on ${_activeExchange!.toUpperCase()}'
          : '';
      return 'Description: Token detail for $_focusedSymbol$ex. '
          'User sees: live price, price chart, 24h volume, high/low, market cap. '
          'Actions: Buy, Sell, Swap, add to watchlist, set price alert. '
          'User can ask about price, trends, risks, volume, liquidity.';
    }
    if (_activeSubScreen == 'exchange_terminal') {
      final ex = _activeExchange ?? 'unknown';
      return 'Description: $ex exchange terminal. Live ticker list. User can browse coins, switch categories (Fast Growth, New, Top, Meme, Majors), tap coin for detail.';
    }
    switch (_activeScreen) {
      case 'ai':
        return 'Description: Voice assistant home. User talks to AI via microphone.';
      case 'chat':
        return 'Description: Text chat with AI. Same capabilities as voice.';
      case 'security':
        return 'Description: Security center. Sub-screens: Guardian Control (Safe/Panic), AI Control (modes/limits), Policy Limits, EPK Control, Audit History, AI Memory.';
      case 'wallet':
        return 'Description: Wallet space. EVM cards (Black/Silver/Gold/Platinum), balances. Actions: Send, Receive, Swap. Can view token details and transaction history.';
      case 'market':
        return 'Description: Market command center. Live exchange terminals: Binance, MEXC, Gate.io, OKX. Actions: browse coins, open exchange, view token details.';
      case 'settings':
        return 'Description: App settings. Actions: change language, set PIN, check updates.';
      default:
        return '';
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Format large values (volume, market cap) in human-readable form.
  static String _fmtLarge(double v) {
    if (v >= 1e12) return '${(v / 1e12).toStringAsFixed(2)}T';
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}
