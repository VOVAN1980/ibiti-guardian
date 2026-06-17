/// Final verdict reached by the SandboxGuard regarding automation.
enum SandboxVerdict {
  approvedForAuto,
  requireManualReview,
  blocked,
}

/// The evaluated outcome of an automated action passing through the Sandbox.
class SandboxDecision {
  final SandboxVerdict verdict;
  final String reason;

  const SandboxDecision(this.verdict, this.reason);

  static SandboxDecision approved(String r) =>
      SandboxDecision(SandboxVerdict.approvedForAuto, r);
  static SandboxDecision manual(String r) =>
      SandboxDecision(SandboxVerdict.requireManualReview, r);
  static SandboxDecision block(String r) =>
      SandboxDecision(SandboxVerdict.blocked, r);
}
