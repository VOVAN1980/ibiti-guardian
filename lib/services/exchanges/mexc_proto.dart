import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';

// ─── MEXC WebSocket Protobuf Messages ─────────────────────────────────────────
//
// Hand-rolled from MEXC's official proto definitions:
// https://github.com/mexcdevelop/websocket-proto
//
// Only the miniTickers stream is needed for market data.
// Full protoc codegen is overkill for 2 simple messages.

// ── PublicMiniTickerV3Api ────────────────────────────────────────────────────

/// Single ticker from MEXC's miniTicker stream.
class MexcMiniTicker extends GeneratedMessage {
  static final BuilderInfo _i = BuilderInfo(
    'PublicMiniTickerV3Api',
    createEmptyInstance: create,
  )
    ..aOS(1, 'symbol')
    ..aOS(2, 'price')
    ..aOS(3, 'rate')
    ..aOS(4, 'zonedRate')
    ..aOS(5, 'high')
    ..aOS(6, 'low')
    ..aOS(7, 'volume')
    ..aOS(8, 'quantity')
    ..aOS(9, 'lastCloseRate')
    ..aOS(10, 'lastCloseZonedRate')
    ..aOS(11, 'lastCloseHigh')
    ..aOS(12, 'lastCloseLow')
    ..hasRequiredFields = false;

  MexcMiniTicker._() : super();

  factory MexcMiniTicker() => create();

  static MexcMiniTicker create() => MexcMiniTicker._();

  @override
  BuilderInfo get info_ => _i;

  @override
  MexcMiniTicker createEmptyInstance() => create();

  @override
  MexcMiniTicker clone() => MexcMiniTicker()..mergeFromMessage(this);

  static MexcMiniTicker fromBuffer(List<int> data) =>
      create()..mergeFromBuffer(data);

  // ── Typed accessors ──────────────────────────────────────────────────────

  /// Trading pair, e.g. "BTCUSDT"
  String get symbol => $_getSZ(0);

  /// Last price as string, e.g. "36474.74"
  String get price => $_getSZ(1);

  /// 24h change ratio (NOT percentage), e.g. "0.0354" = +3.54%
  String get rate => $_getSZ(2);

  /// Timezone-adjusted change ratio.
  String get zonedRate => $_getSZ(3);

  /// 24h high price.
  String get high => $_getSZ(4);

  /// 24h low price.
  String get low => $_getSZ(5);

  /// 24h quote volume (USDT amount).
  String get volume => $_getSZ(6);

  /// 24h base volume (token quantity).
  String get quantity => $_getSZ(7);
}

// ── PublicMiniTickersV3Api ───────────────────────────────────────────────────

/// Array of mini tickers — the main message from `spot@public.miniTickers.v3.api.pb@UTC+8`.
class MexcMiniTickers extends GeneratedMessage {
  static final BuilderInfo _i = BuilderInfo(
    'PublicMiniTickersV3Api',
    createEmptyInstance: create,
  )
    ..pc<MexcMiniTicker>(1, 'items', PbFieldType.PM,
        subBuilder: MexcMiniTicker.create)
    ..hasRequiredFields = false;

  MexcMiniTickers._() : super();

  factory MexcMiniTickers() => create();

  static MexcMiniTickers create() => MexcMiniTickers._();

  @override
  BuilderInfo get info_ => _i;

  @override
  MexcMiniTickers createEmptyInstance() => create();

  @override
  MexcMiniTickers clone() => MexcMiniTickers()..mergeFromMessage(this);

  static MexcMiniTickers fromBuffer(List<int> data) =>
      create()..mergeFromBuffer(data);

  /// All tickers in this push.
  List<MexcMiniTicker> get items => $_getList(0);
}

// ── PushDataV3ApiWrapper ────────────────────────────────────────────────────

/// Top-level WS wrapper. Contains channel name + oneof body.
/// We only care about field 310 = publicMiniTickers.
class MexcPushWrapper extends GeneratedMessage {
  // Tag numbers matching the proto definition:
  // channel = 1, publicMiniTickers = 310, symbol = 3, createTime = 5, sendTime = 6
  static const int _tagMiniTickers = 310;

  static final BuilderInfo _i = BuilderInfo(
    'PushDataV3ApiWrapper',
    createEmptyInstance: create,
  )
    ..aOS(1, 'channel')
    ..aOM<MexcMiniTickers>(_tagMiniTickers, 'publicMiniTickers',
        subBuilder: MexcMiniTickers.create)
    ..aOS(3, 'symbol')
    ..a<Int64>(5, 'createTime', PbFieldType.O6, defaultOrMaker: Int64.ZERO)
    ..a<Int64>(6, 'sendTime', PbFieldType.O6, defaultOrMaker: Int64.ZERO)
    ..hasRequiredFields = false;

  MexcPushWrapper._() : super();

  factory MexcPushWrapper() => create();

  static MexcPushWrapper create() => MexcPushWrapper._();

  @override
  BuilderInfo get info_ => _i;

  @override
  MexcPushWrapper createEmptyInstance() => create();

  @override
  MexcPushWrapper clone() => MexcPushWrapper()..mergeFromMessage(this);

  static MexcPushWrapper fromBuffer(List<int> data) =>
      create()..mergeFromBuffer(data);

  /// Channel name, e.g. "spot@public.miniTickers.v3.api.pb@UTC+8"
  String get channel => $_getSZ(0);

  /// The mini tickers array (field 310). Null if this message is a different type.
  MexcMiniTickers? get publicMiniTickers {
    if (!$_has(1)) return null;
    return $_getN(1);
  }

  bool get hasPublicMiniTickers => $_has(1);
}
