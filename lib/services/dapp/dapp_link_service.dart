import 'dart:async';
import 'package:app_links/app_links.dart';
import 'dapp_protocol.dart';

/// Cold/warm browser links are held until the authenticated app shell is ready.
/// Privy's ibitiguardian:// OAuth redirect is deliberately not handled here.
class DappLinkService {
  DappLinkService._();
  static final instance = DappLinkService._();
  StreamSubscription<Uri>? _subscription;
  Uri? _pending;
  Uri? _lastLink;
  DateTime? _lastReceivedAt;
  void Function(Uri)? _open;

  Future<void> start() async {
    if (_subscription != null) return;
    final links = AppLinks();
    _subscription = links.uriLinkStream.listen(_receive, onError: (_) {});
    try {
      final initial = await links.getInitialLink();
      if (initial != null) _receive(initial);
    } catch (_) {}
  }

  void _receive(Uri link) {
    final url = DappOrigin.browserLink(link);
    if (url == null) return;
    // Some platforms deliver the cold-start link through both APIs.
    final now = DateTime.now();
    if (url == _lastLink &&
        _lastReceivedAt != null &&
        now.difference(_lastReceivedAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastLink = url;
    _lastReceivedAt = now;
    if (_open == null) {
      _pending = url;
    } else {
      _open!(url);
    }
  }

  void attach(void Function(Uri) open) {
    _open = open;
    final pending = _pending;
    _pending = null;
    if (pending != null) open(pending);
  }

  void detach() {
    _open = null;
  }
}
