class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  @override
  String toString() {
    return 'Candle(time: $time, O: $open, H: $high, L: $low, C: $close, V: $volume)';
  }
}
