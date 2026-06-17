/// Detailed result of a validation check by an EPK Validator.
class EpkValidatorResult {
  final bool isValid;

  /// The reason why it was rejected. Will be null if isValid == true.
  final String? rejectionReason;

  /// The severity of the rejection.
  final String severity;

  /// A human-readable message intended to be shown on the UI to the user.
  final String? userMessage;

  /// Detailed internal state or context for developers/debug logs.
  final String? debugDetails;

  const EpkValidatorResult({
    required this.isValid,
    this.rejectionReason,
    this.severity = 'info',
    this.userMessage,
    this.debugDetails,
  });

  factory EpkValidatorResult.pass() => const EpkValidatorResult(isValid: true);

  factory EpkValidatorResult.reject({
    required String reason,
    required String userMessage,
    String? debugDetails,
    String severity = 'danger',
  }) {
    return EpkValidatorResult(
      isValid: false,
      rejectionReason: reason,
      userMessage: userMessage,
      debugDetails: debugDetails,
      severity: severity,
    );
  }
}
