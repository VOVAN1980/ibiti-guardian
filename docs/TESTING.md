# Testing & Policy Verification Suite

To guarantee that the **Heuristic Policy Engine** and **SandboxGuard** work correctly under all scenarios, the codebase includes a comprehensive suite of unit and integration tests.

---

## 📊 Test Coverage Summary

Our test suite consists of **79 dedicated test cases** covering the following safety gates:

### Heuristic Policy Engine Tests
1. **Manual Mode enforcement**: Verifies that any trade request is automatically blocked when the app is in `Manual` autonomy mode.
2. **Allowed actions validation**: Blocks actions (e.g. transfer, swap) if they are disabled in settings.
3. **Budget limit checks**:
   * Blocks trades exceeding the single-transaction cap.
   * Blocks trades exceeding the remaining daily budget.
4. **Exchange verification**:
   * Rejects orders targeting inactive or unconfigured centralized exchanges.
   * Enforces minimum trade limits (e.g., MEXC's $5 minimum limit).
5. **Dynamic Slippage & Price Impact validation**:
   * Blocks swap operations if proposed slippage exceeds the configured cap.
   * Blocks swaps with >5% price impact.
   * Warns and requests confirmation for swaps with 1-5% price impact.

### SandboxGuard Tests
1. **Pre-flight RPC Simulation**: Mock-tests state changes to verify asset flow safety.
2. **Risk Mitigation**: Ensures high-risk addresses are blocked by default.
3. **Automatic Risk Downgrade**: Verifies that adding a young or untrusted contract to the "Trusted Address Book" successfully downgrades its block status to a manual confirmation gate.
4. **Unlimited Approval Block**: Checks that requests for infinite allowances are caught and limited to the exact transaction amount.

---

## 🛠 Running the Tests

To execute the test suite and verify code compliance:

1. Make sure the Flutter SDK is installed and configured in your path.
2. Run the following command from the root of the repository:

```bash
flutter test test/services/policy/guardian_policy_engine_test.dart
flutter test test/services/policy/sandbox_guard_test.dart
```

To run all unit tests in the repository:

```bash
flutter test
```
