import 'dapp_protocol.dart';

/// Native approval is tied to the shown preview and the same request object.
/// It is not a website permission, persistent allowlist, or reusable grant.
class DappTransactionConsent {
  final DappTransaction transaction;
  final DappApproval preview;
  bool _confirmed = false;
  bool _consumed = false;
  DappTransactionConsent(this.transaction, this.preview);

  void confirm(DappTransaction tx, DappApproval shown) {
    if (_consumed || _confirmed || !identical(tx, transaction) ||
        !identical(shown, preview)) {
      throw const DappError(4100, 'The transaction approval does not match.');
    }
    _confirmed = true;
  }

  void consume(DappTransaction tx) {
    if (!_confirmed || _consumed || !identical(tx, transaction)) {
      throw const DappError(4100, 'A native transaction confirmation is required.');
    }
    _consumed = true;
  }
}
