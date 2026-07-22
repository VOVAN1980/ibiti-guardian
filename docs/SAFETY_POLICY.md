# Safety Policy & Shield Parameters

Safety is the primary value proposition of **IBITI Guardian**. Unlike traditional wallets or AI assistants that blindly sign user or agent requests, Guardian acts as a protective shield checking every parameter.

---

## 🧠 AI Autonomy Modes

| Autonomy Mode | Execution Behavior | Verification Requirement | Best For |
|---------------|-------------------|--------------------------|----------|
| **Manual** | AI only provides explanations and checks prices. Cannot prepare or execute transactions. | N/A (Blocked) | Reviewing code and learning |
| **Guarded** | AI drafts the transaction, but the user must explicitly sign via biometrics/PIN on screen. | PIN or Biometric Unlock | Standard daily trading |
| **Full Autonomy** | AI automatically executes trades when conditions are met. | Zero-click (auto-signing within limits) | Automated algorithmic radar trading |

---

## 📊 Execution Limits (Shield Constraints)

The Policy Engine checks every transaction against these strict, user-defined thresholds:

* **Per-Transaction Limit**: Prevents the AI from accidentally placing a massive order (e.g. $10,000 instead of $10).
* **Daily Budget Limit**: Restricts the maximum cumulative dollar volume allowed in a 24-hour period.
* **Minimum Order Size**: Blocks orders below exchange minimums (e.g., MEXC's $5 minimum) to prevent wasting funds on incomplete executions.
* **Allowed Networks & Assets**: Limits execution to pre-approved networks (e.g., BSC, Polygon) and tokens (e.g., SOL, USDT) to block rugpulls or spam coins.
* **Allowed Platform Status**: Only allows actions on active, connected CEXs or verified Web3 RPC endpoints.

---

## 🚨 Safety Gates & Guards

### 1. SandboxGuard
Before signing any Web3 transaction, the transaction payload is run in a local pre-flight sandbox.
* **State Check**: SandboxGuard inspects simulated wallet balances before and after the call. If the simulation results in unexpected asset outflows, it immediately aborts the trade.
* **Proxy and Code Integrity**: Detects if the contract target has upgradeable proxy attributes or suspicious self-destruct methods.

### 2. Slippage & Price Impact Caps
* **Price Impact**: If a swap will result in a price impact between **1% and 5%**, the app flags a warning requiring manual confirmation. If the price impact exceeds **5%**, the transaction is blocked entirely to prevent frontrunning/sandwich attacks.
* **Slippage Cap**: User-defined slippage tolerance (max Bps) is checked against the swap provider routing.

### 3. Unlimited Approval Protection
Web3 apps commonly request "unlimited approvals" to spend tokens, leaving users vulnerable. IBITI Guardian:
* Restricts unlimited approvals by default.
* Automatically limits approvals to the exact amount required for the specific transaction, unless overridden by explicit policies.

### 4. High-Risk Wallet Downgrade Heuristic
If a static check flags an address as high-risk (untrusted contract, young age), the transaction is blocked. However, if the address is added to the user's **Trusted Address Book**, the policy engine automatically downgrades the risk rating to a warning confirmation, allowing the trade to proceed under manual supervision.

### 5. CEX Withdrawal Keys Safety
When adding centralized exchange API credentials (MEXC, OKX, Gate.io, Binance), the app scans the API key capabilities. Keys with **Withdrawal (transfer out of account) permissions enabled are strictly blocked** from being added to the database.
