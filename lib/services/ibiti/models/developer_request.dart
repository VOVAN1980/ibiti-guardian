// ─── Developer Request ──────────────────────────────────────────────────────
//
// Phase 10B+10E: JARVIS → Developer/User communication channel.
//
// When JARVIS identifies a systemic problem through diagnostic analysis,
// it creates a DeveloperRequest — a concrete, evidence-backed request
// for a code/config/policy change.
//
// JARVIS doesn't just say "fix it". It says:
//   - Here's the problem (with data)
//   - Here's what I need changed
//   - Here's what I expect to happen
//   - Here's how to verify it worked
//
// Not an alarm. An official request with evidence.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'trade_diagnostic_result.dart';

/// What kind of change is being requested.
enum DeveloperRequestType {
  codeChange,
  dataSource,
  policyChange,
  limitChange,
  strategyChange,
  connectorRequest,
  memoryRequest,
  investigation,
}

/// Lifecycle status of a request.
enum DeveloperRequestStatus {
  open,
  acknowledged,
  inProgress,
  implemented,
  rejected,
  obsolete,
  needsMoreEvidence,
}

/// Who should see this request.
enum DeveloperRequestAudience {
  developer,
  user,
  operator,
  policy,
}

/// A concrete, evidence-backed request from JARVIS to developers/users.
class DeveloperRequest {
  /// Unique identifier for dedup and tracking.
  /// Format: CATEGORY_SPECIFIC_ISSUE (e.g. NORMAL_MOMENTUM_EXHAUSTION_FILTER).
  final String id;

  /// What kind of change.
  final DeveloperRequestType type;

  /// Current lifecycle status.
  DeveloperRequestStatus status;

  /// Who should see this.
  final DeveloperRequestAudience audience;

  /// How urgent is this request.
  final DiagnosticSeverity priority;

  /// What is the problem (short).
  final String problem;

  /// Evidence: numbers, trade counts, PnL impact.
  final String evidence;

  /// What JARVIS wants changed (concrete action).
  final String requestedChange;

  /// What JARVIS expects after the change.
  final String expectedImpact;

  /// How to verify the change worked.
  final String verificationPlan;

  /// Which symbols were most affected.
  final List<String> affectedSymbols;

  /// Which strategies are involved.
  final List<String> affectedStrategies;

  /// Which diagnostic reasons triggered this request.
  final List<TradeDiagnosticReason> triggeringReasons;

  /// How many trades support this conclusion.
  int supportingTradeCount;

  /// Total PnL impact of the problem.
  double pnlImpact;

  /// Estimated missed PnL.
  double missedPnlEstimate;

  /// Confidence in this request.
  final double confidence;

  /// Related strategy knowledge ID.
  final String? relatedStrategyId;

  /// Related rule ID.
  final String? relatedRuleId;

  /// When this request was generated.
  final DateTime createdAt;

  /// Last updated.
  DateTime updatedAt;

  DeveloperRequest({
    required this.id,
    this.type = DeveloperRequestType.codeChange,
    this.status = DeveloperRequestStatus.open,
    this.audience = DeveloperRequestAudience.developer,
    required this.priority,
    required this.problem,
    required this.evidence,
    required this.requestedChange,
    required this.expectedImpact,
    required this.verificationPlan,
    this.affectedSymbols = const [],
    this.affectedStrategies = const [],
    this.triggeringReasons = const [],
    this.supportingTradeCount = 0,
    this.pnlImpact = 0,
    this.missedPnlEstimate = 0,
    this.confidence = 0.5,
    this.relatedStrategyId,
    this.relatedRuleId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Compact log line.
  String toLogLine() => '[DEV_REQUEST] $id type=${type.name} '
      'status=${status.name} priority=${priority.name} '
      'trades=$supportingTradeCount '
      'impact=\$${pnlImpact.toStringAsFixed(4)} '
      'missed=\$${missedPnlEstimate.toStringAsFixed(4)} '
      'conf=${confidence.toStringAsFixed(2)} '
      'fix="$requestedChange"';

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'status': status.name,
        'audience': audience.name,
        'priority': priority.name,
        'problem': problem,
        'evidence': evidence,
        'requestedChange': requestedChange,
        'expectedImpact': expectedImpact,
        'verificationPlan': verificationPlan,
        'affectedSymbols': affectedSymbols,
        'affectedStrategies': affectedStrategies,
        'triggeringReasons': triggeringReasons.map((r) => r.name).toList(),
        'supportingTradeCount': supportingTradeCount,
        'pnlImpact': pnlImpact,
        'missedPnlEstimate': missedPnlEstimate,
        'confidence': confidence,
        'relatedStrategyId': relatedStrategyId,
        'relatedRuleId': relatedRuleId,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// Build from DB row.
  factory DeveloperRequest.fromRow(Map<String, dynamic> r) {
    final reasons = r['triggering_reasons_json'] as String? ?? '[]';
    final syms = r['affected_symbols_json'] as String? ?? '[]';
    final strats = r['affected_strategies_json'] as String? ?? '[]';

    return DeveloperRequest(
      id: r['id'] as String? ?? '',
      type: DeveloperRequestType.values.firstWhere(
        (t) => t.name == (r['type'] as String? ?? ''),
        orElse: () => DeveloperRequestType.codeChange,
      ),
      status: DeveloperRequestStatus.values.firstWhere(
        (s) => s.name == (r['status'] as String? ?? ''),
        orElse: () => DeveloperRequestStatus.open,
      ),
      audience: DeveloperRequestAudience.values.firstWhere(
        (a) => a.name == (r['audience'] as String? ?? ''),
        orElse: () => DeveloperRequestAudience.developer,
      ),
      priority: DiagnosticSeverity.values.firstWhere(
        (p) => p.name == (r['priority'] as String? ?? ''),
        orElse: () => DiagnosticSeverity.warning,
      ),
      problem: r['problem'] as String? ?? '',
      evidence: r['evidence'] as String? ?? '',
      requestedChange: r['requested_change'] as String? ?? '',
      expectedImpact: r['expected_impact'] as String? ?? '',
      verificationPlan: r['verification_plan'] as String? ?? '',
      affectedSymbols: (jsonDecode(syms) as List).cast<String>(),
      affectedStrategies: (jsonDecode(strats) as List).cast<String>(),
      triggeringReasons: (jsonDecode(reasons) as List)
          .map((n) => TradeDiagnosticReason.values.firstWhere(
                (r) => r.name == n,
                orElse: () => TradeDiagnosticReason.unknown,
              ))
          .toList(),
      supportingTradeCount: r['supporting_trade_count'] as int? ?? 0,
      pnlImpact: (r['pnl_impact'] as num?)?.toDouble() ?? 0,
      missedPnlEstimate: (r['missed_pnl_estimate'] as num?)?.toDouble() ?? 0,
      confidence: (r['confidence'] as num?)?.toDouble() ?? 0.5,
      relatedStrategyId: r['related_strategy_id'] as String?,
      relatedRuleId: r['related_rule_id'] as String?,
      createdAt:
          DateTime.tryParse(r['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(r['updated_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  /// Convert to DB row map.
  Map<String, dynamic> toRow() => {
        'id': id,
        'type': type.name,
        'status': status.name,
        'audience': audience.name,
        'priority': priority.name,
        'problem': problem,
        'evidence': evidence,
        'requested_change': requestedChange,
        'expected_impact': expectedImpact,
        'verification_plan': verificationPlan,
        'affected_symbols_json': jsonEncode(affectedSymbols),
        'affected_strategies_json': jsonEncode(affectedStrategies),
        'triggering_reasons_json':
            jsonEncode(triggeringReasons.map((r) => r.name).toList()),
        'supporting_trade_count': supportingTradeCount,
        'pnl_impact': pnlImpact,
        'missed_pnl_estimate': missedPnlEstimate,
        'confidence': confidence,
        'related_strategy_id': relatedStrategyId,
        'related_rule_id': relatedRuleId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  @override
  String toString() => toLogLine();
}
