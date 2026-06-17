import 'package:ibiti_guardian/services/policy/epk_adapter.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

/// Evaluates constraints vs capability to decide the safest reliable execution path.
/// Caches result to avoid pinging network/factory mappings repeatedly per session.
class EpkCapabilityResolver {
  EpkCapabilityResolver._();
  static final instance = EpkCapabilityResolver._();

  final EpkAdapter _epk = EpkAdapter.instance;

  /// Cached status (TTL 5 mins logic handled implicitly here for Phase 5)
  bool? _cachedIsDeployed;
  DateTime? _lastChecked;
  String? _lastCheckedWallet;
  int? _lastCheckedChain;

  Future<ExecutionPath> resolvePath(String walletAddress, int chainId) async {
    final epkAvailable = await _checkAvailability(walletAddress, chainId);

    // If on-chain EPK is not truly configured, stay on the protected local path
    // instead of pretending we can route via the kernel.
    if (!epkAvailable) {
      return ExecutionPath.localProtected;
    }

    // EPK is supported AND configured - we can use EPK Protected
    return ExecutionPath.epkProtected;
  }

  Future<bool> _checkAvailability(String walletAddress, int chainId) async {
    final epkState = EPKPolicyManager.instance.state;
    if (!epkState.isActive) {
      _cachedIsDeployed = false;
      _lastCheckedWallet = walletAddress;
      _lastCheckedChain = chainId;
      _lastChecked = DateTime.now();
      return false;
    }

    final now = DateTime.now();

    // Cache hit criteria
    if (_cachedIsDeployed != null &&
        _lastCheckedWallet == walletAddress &&
        _lastCheckedChain == chainId &&
        _lastChecked != null &&
        now.difference(_lastChecked!).inMinutes < 5) {
      return _cachedIsDeployed!;
    }

    // Cache miss - resolve
    final isDeployed = await _epk.isEpkDeployed(walletAddress, chainId);

    _cachedIsDeployed = isDeployed;
    _lastCheckedWallet = walletAddress;
    _lastCheckedChain = chainId;
    _lastChecked = now;

    return isDeployed;
  }

  /// Forces clear of the capability cache, e.g., if user switches wallets manually
  void invalidateCache() {
    _cachedIsDeployed = null;
    _lastChecked = null;
  }
}
