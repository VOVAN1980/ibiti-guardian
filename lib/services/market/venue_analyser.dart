import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';

/// Result of a venue analysis for a specific asset.
///
/// All venues are sourced from CoinGecko ticker/exchange metadata.
/// These are **NOT live order-book quotes** — no real-time bid/ask comparison
/// is performed. The labels "preferred" intentionally signal this.
class VenueAnalysis {
  /// Venue with the highest known volume — preferred for buying.
  final String preferredBuyVenue;

  /// Venue with the highest known volume — preferred for selling.
  /// Often the same as buy venue; distinguished when mandate filters apply.
  final String preferredSellVenue;

  /// Human-readable route note. Always states data source honestly.
  final String routeNote;

  /// All venues that pass the mandate's allowedVenues filter.
  final List<String> allowedVenues;

  /// Venues that exist in detail but are blocked by mandate.
  final List<String> blockedVenues;

  const VenueAnalysis({
    required this.preferredBuyVenue,
    required this.preferredSellVenue,
    required this.routeNote,
    required this.allowedVenues,
    required this.blockedVenues,
  });
}

/// Derives venue preferences from CoinGecko exchange metadata.
///
/// This is a metadata-based analyser. It does not connect to exchanges
/// or fetch live order books. It ranks available venue names from
/// `MarketAssetDetail.venues` by position (CoinGecko returns highest-volume
/// venues first) and filters by mandate.allowedVenues.
class VenueAnalyser {
  VenueAnalyser._();

  static const String _fallback = 'Best available venue';

  static VenueAnalysis analyse(
    MarketAsset asset,
    MarketAssetDetail? detail,
    AutonomyMandate mandate, {
    String? userPreferredVenue,
  }) {
    final rawVenues = detail?.venues ?? const <String>[];

    // ── Mandate venue filter ─────────────────────────────────────────────────
    // CoinGecko tickers list venues in volume-descending order,
    // so the first allowed venue is the most liquid known option.
    final allowed = <String>[];
    final blocked = <String>[];

    for (final venue in rawVenues) {
      if (mandate.allowsVenue(venue)) {
        allowed.add(venue);
      } else {
        blocked.add(venue);
      }
    }

    // ── User preference boost ────────────────────────────────────────────────
    // If the user has a preferred venue AND it passed the mandate filter,
    // move it to the front of the list so it becomes the default choice.
    if (userPreferredVenue != null && allowed.length > 1) {
      final prefLower = userPreferredVenue.toLowerCase();
      final idx = allowed.indexWhere((v) => v.toLowerCase() == prefLower);
      if (idx > 0) {
        final pref = allowed.removeAt(idx);
        allowed.insert(0, pref);
      }
    }

    // ── Preferred venues ─────────────────────────────────────────────────────
    // First in list = highest known volume (CoinGecko order).
    final preferredBuy = allowed.isNotEmpty ? allowed.first : _fallback;

    // For selling, prefer the same top venue or second if available.
    // Without live spread data we cannot distinguish buy vs sell depth.
    final preferredSell = allowed.length >= 2 ? allowed[1] : preferredBuy;

    // ── Route note ────────────────────────────────────────────────────────────
    String routeNote;
    if (rawVenues.isEmpty) {
      routeNote = 'No venue metadata available from CoinGecko. '
          'Use a DEX aggregator (0x, 1inch) for actual routing.';
    } else if (mandate.allowedVenues.isNotEmpty && allowed.isEmpty) {
      routeNote =
          'All known venues (${rawVenues.take(3).join(", ")}) are blocked '
          'by your mandate allowedVenues. Cannot route this asset.';
    } else if (blocked.isNotEmpty) {
      routeNote =
          'Using $preferredBuy (${blocked.length} venue(s) blocked by mandate). '
          'Source: CoinGecko exchange metadata — not live order-book data.';
    } else {
      routeNote = 'Preferred venue from CoinGecko exchange metadata. '
          'Not a live order-book quote — use DEX/bridge aggregator for exact execution.';
    }

    return VenueAnalysis(
      preferredBuyVenue: preferredBuy,
      preferredSellVenue: preferredSell,
      routeNote: routeNote,
      allowedVenues: allowed,
      blockedVenues: blocked,
    );
  }
}
