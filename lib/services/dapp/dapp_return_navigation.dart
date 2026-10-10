import 'dapp_protocol.dart';

/// Navigation only: this never signs, submits or cancels a payment.
class DappReturnNavigation {
  static const lvsReturn = 'lvs://wallet/withdrawal';

  static bool allows({
    required String? source,
    required String target,
    required bool isMainFrame,
  }) {
    if (!isMainFrame || target != lvsReturn || source == null) return false;
    try {
      final page = DappOrigin.httpsUrl(source);
      return page.origin == 'https://api.lvs.network' &&
          RegExp(r'^/v1/wallet/evm-pay/[a-zA-Z0-9_:-]{1,256}/?$')
              .hasMatch(page.path);
    } on DappError {
      return false;
    }
  }
}
