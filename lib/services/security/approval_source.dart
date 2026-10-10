import 'package:ibiti_guardian/models/approval.dart';

/// A complete, read-only ERC-20 approval scan. Never return a partial list as
/// success: callers interpret an empty successful list as no active approvals.
abstract class ApprovalSource {
  Future<List<ApprovalData>> fetch(
    String wallet, {
    required int chainId,
    String? targetTokenAddress,
  });
}

/// Only diagnostic codes, never provider bodies, URLs, keys or wallet data.
class ApprovalSourceException implements Exception {
  const ApprovalSourceException(this.code);
  final String code;

  @override
  String toString() => 'ApprovalSourceException($code)';
}
